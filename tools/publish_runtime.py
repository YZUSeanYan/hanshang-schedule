"""本地签名 import-runtime payload，然后原子发布到服务器 /data/import-runtime-v1.json。

用法：python publish_runtime.py payload.json [--publish]
回滚：不允许降 revision；改内容后用更高 revision 重发。

校验规则与客户端 ImportRuntime.fromPayload 严格一致（schema 1/2，
含 schools 条目的 URL/防注入/规模约束）。签名私钥：
  ~/.ssh/your-import-runtime-signing-key.pem
发布通道：ssh deploy@your-server.example（密钥 ~/.ssh/your-ssh-key）
  → docker exec -i yzu-schedule-api python -（flock 原子替换，旧版归档
    /data/import-runtime-history/<rev>.json，拒绝 revision 回退）
"""
from pathlib import Path
import sys, json, base64, time, subprocess, re, shutil
from urllib.parse import urlparse
from cryptography.hazmat.primitives import serialization

PUBLISH_HOST = 'deploy@your-server.example'
PUBLISH_KEY = Path.home() / '.ssh' / 'your-ssh-key'
CONTAINER = 'yzu-schedule-api'


def stage_ssh_key() -> str:
    """用户目录含撇号时，Windows ssh.exe 可能错误解析参数——
    先把私钥暂存到无撇号的 secrets 目录再引用（仅本机，不上传）。"""
    dst_dir = Path(r'C:\path\to\secrets\ssh-runtime')
    dst_dir.mkdir(parents=True, exist_ok=True)
    dst = dst_dir / PUBLISH_KEY.name
    if not dst.exists() or dst.read_bytes() != PUBLISH_KEY.read_bytes():
        shutil.copyfile(PUBLISH_KEY, dst)
    return str(dst)

data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))

targets = {'courseName', 'teacherName', 'location', 'dayOfWeek',
           'startSection', 'endSection', 'weeksText', 'timeAndPlaceList'}

# ---- 顶层校验（schema 1/2 共用）----
assert data['schema'] in (1, 2), 'schema must be 1 or 2'
assert isinstance(data['revision'], int) and data['revision'] > 0
assert data['expiresAt'] > int(time.time())
assert data['issuedAt'] <= int(time.time()) + 300
assert data['minBuild'] >= 34 and data['maxBuild'] >= data['minBuild']
uri = urlparse(data['entryUrl'])
assert uri.scheme == 'https' and uri.hostname and (
    uri.hostname == 'yzu.edu.cn' or uri.hostname.endswith('.yzu.edu.cn'))
assert not uri.username and not uri.password and uri.port in (None, 443) and not uri.fragment
assert isinstance(data.get('enabled'), bool)
assert isinstance(data.get('guide', ''), str) and len(data.get('guide', '')) <= 1200
hints = data.get('urlHints', [])
assert isinstance(hints, list) and len(hints) <= 24 and all(
    isinstance(v, str) and 3 <= len(v) <= 80 and re.fullmatch(r'[a-zA-Z0-9_/.-]+', v)
    for v in hints)
aliases = data.get('fieldAliases', {})
assert isinstance(aliases, dict) and len(aliases) <= 32 and all(
    re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_]{0,63}', k) and v in targets
    for k, v in aliases.items())
certs = data.get('intermediates', [])
assert isinstance(certs, list) and len(certs) <= 8 and all(
    isinstance(v, str) and 0 < len(v) <= 22000
    and len(base64.b64decode(v, validate=True)) <= 16384 for v in certs)

# ---- schema 2：schools 条目（与客户端 RuntimeSchool.fromPayload 一致）----
schools = data.get('schools', [])
assert isinstance(schools, list) and len(schools) <= 400, 'schools must be a list <= 400'
seen_hosts = set()
for s in schools:
    assert isinstance(s, dict), 'school entry must be an object'
    name, url = s.get('name'), s.get('url')
    assert isinstance(name, str) and 0 < len(name) <= 80, f'bad name: {name!r}'
    assert isinstance(url, str) and 0 < len(url) <= 2048, f'bad url: {url!r}'
    u = urlparse(url)
    assert u.scheme == 'https' and u.hostname, f'bad url scheme/host: {url}'
    assert not u.username and not u.password and u.port in (None, 443) and not u.fragment, url
    host = u.hostname.lower()
    assert host not in seen_hosts, f'duplicate school host: {host}'
    seen_hosts.add(host)
    assert isinstance(s.get('system', ''), str) and len(s.get('system', '')) <= 32
    assert isinstance(s.get('guide', ''), str) and len(s.get('guide', '')) <= 600
    initial = s.get('initial', '')
    assert initial == '' or re.fullmatch(r'[A-Z]', initial), f'bad initial: {initial!r}'
    sh = s.get('urlHints', [])
    assert isinstance(sh, list) and len(sh) <= 8 and all(
        isinstance(v, str) and 3 <= len(v) <= 80
        and re.fullmatch(r'[a-zA-Z0-9_/.-]+', v) for v in sh), f'bad hints: {name}'
    sa = s.get('fieldAliases', {})
    assert isinstance(sa, dict) and len(sa) <= 16 and all(
        re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_]{0,63}', k) and v in targets
        for k, v in sa.items()), f'bad aliases: {name}'
    sc = s.get('intermediates', [])
    assert isinstance(sc, list) and len(sc) <= 2 and all(
        isinstance(v, str) and 0 < len(v) <= 22000
        and len(base64.b64decode(v, validate=True)) <= 16384 for v in sc), f'bad certs: {name}'

# ---- 签名 ----
key = serialization.load_pem_private_key(
    (Path.home() / '.ssh/your-import-runtime-signing-key.pem').read_bytes(), password=None)
payload = json.dumps(data, ensure_ascii=False, separators=(',', ':')).encode()
signed = json.dumps(dict(
    payload=base64.b64encode(payload).decode(),
    signature=base64.b64encode(key.sign(payload)).decode()),
    separators=(',', ':')).encode()
assert len(signed) <= 196608, f'envelope too large: {len(signed)}'

root = Path(__file__).resolve().parent
(root / 'import-runtime-v1.json').write_bytes(signed)
print(f"Signed revision {data['revision']} "
      f"({len(signed)} bytes, {len(schools)} schools)")

if '--publish' in sys.argv:
    script = '''from pathlib import Path
import json,base64,os,time,fcntl
p=Path('/data/import-runtime-v1.json')
lock=(p.parent/'import-runtime-publish.lock').open('a')
fcntl.flock(lock,fcntl.LOCK_EX)
new=base64.b64decode(%r)
revision=json.loads(base64.b64decode(json.loads(new)['payload']))['revision']
if p.exists():
    old=p.read_bytes()
    old_revision=json.loads(base64.b64decode(json.loads(old)['payload']))['revision']
    assert revision>old_revision,'Revision must increase; rollback uses a new revision'
    b=p.parent/'import-runtime-history';b.mkdir(exist_ok=True)
    (b/(str(old_revision)+'.json')).write_bytes(old)
temp=p.with_suffix('.tmp')
with temp.open('wb') as f:f.write(new);f.flush();os.fsync(f.fileno())
temp.chmod(0o644);temp.replace(p)
print('Published revision',revision)
''' % base64.b64encode(signed).decode()
    subprocess.run(
        ['ssh', '-o', 'BatchMode=yes', '-i', stage_ssh_key(), PUBLISH_HOST,
         f'docker exec -i {CONTAINER} python -'],
        input=script.encode(), check=True)
