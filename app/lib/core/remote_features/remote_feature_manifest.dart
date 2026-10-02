import 'dart:convert';

/// A signed, server-delivered product surface.
///
/// The manifest can add links to hosted modules, but it cannot download or
/// execute new Dart/native code. Native capabilities remain compiled and
/// explicitly allow-listed by the APK.
enum RemoteFeaturePlacement {
  importTop('import_top'),
  scheduleTools('schedule_tools'),
  profile('profile'),
  featureHub('feature_hub');

  const RemoteFeaturePlacement(this.wireName);
  final String wireName;

  static RemoteFeaturePlacement parse(String value) => values.firstWhere(
        (item) => item.wireName == value,
        orElse: () => throw const FormatException('Invalid placement'),
      );
}

enum RemoteFeatureCapability {
  documentPicker('document_picker'),
  imagePicker('image_picker'),
  scheduleRead('schedule_read'),
  scheduleWrite('schedule_write'),
  share('share'),
  notifications('notifications');

  const RemoteFeatureCapability(this.wireName);
  final String wireName;

  static RemoteFeatureCapability parse(String value) => values.firstWhere(
        (item) => item.wireName == value,
        orElse: () => throw const FormatException('Invalid capability'),
      );
}

enum RemoteFeatureAudience {
  all,
  targeted;

  static RemoteFeatureAudience parse(Object? value) => switch (value) {
        null || 'all' => all,
        'targeted' => targeted,
        _ => throw const FormatException('Invalid feature audience'),
      };
}

class RemotePrivacyPolicy {
  const RemotePrivacyPolicy({
    required this.id,
    required this.revision,
    required this.effectiveDate,
    required this.summary,
    required this.body,
    this.requiresReconsent = true,
  });

  final String id;
  final int revision;
  final String effectiveDate;
  final String summary;
  final String body;
  final bool requiresReconsent;

  factory RemotePrivacyPolicy.fromJson(Map<String, dynamic> json) {
    final id = _boundedString(json['id'], 80);
    final revision = json['revision'];
    final effectiveDate = _boundedString(json['effectiveDate'], 40);
    final summary = _boundedString(json['summary'], 1600);
    final body = _boundedString(json['body'], 50000);
    final requiresReconsent = json['requiresReconsent'];
    if (!RegExp(r'^privacy-[a-zA-Z0-9._-]{1,64}$').hasMatch(id) ||
        revision is! int ||
        revision < 1 ||
        id != 'privacy-v$revision' ||
        requiresReconsent is! bool) {
      throw const FormatException('Invalid privacy policy');
    }
    return RemotePrivacyPolicy(
      id: id,
      revision: revision,
      effectiveDate: effectiveDate,
      summary: summary,
      body: body,
      requiresReconsent: requiresReconsent,
    );
  }
}

const bundledPrivacyPolicyId = 'privacy-v7';

/// 内置政策 v7（2026 年 9 月 22 日）：统一 App、网页版与官网的政策文本：补充网页版 AI 日程的文字与图片录入说明，订正共同空闲的用户名搜索描述，合并此前分散的说明。
/// 全文须与 privacy_policy_page.dart 的分节内容保持一致；
/// 由 tools/privacy_policy.py 生成，勿手改。
const bundledPrivacyPolicy = RemotePrivacyPolicy(
  id: bundledPrivacyPolicyId,
  revision: 7,
  effectiveDate: '2026 年 9 月 22 日',
  summary: '统一 App、网页版与官网的政策文本：补充网页版 AI 日程的文字与图片录入说明，订正共同空闲的用户名搜索描述，合并此前分散的说明。',
  body: '邗上课表隐私政策\n\n'
      '生效日期：2026 年 9 月 22 日（第 7 版）\n\n'
      '一、我们处理的信息\n'
      '为提供账号登录、课表导入与同步、课程与日程提醒、账户通知、共同空闲和安全保障，我们处理以下必要信息：\n\n'
      '① 账号信息：你主动提供的用户名和邮箱，用于登录、找回密码、用户名邀请和识别通知归属。登录密码只以 bcrypt 不可逆哈希存储，包括管理员在内的任何人都无法取得明文；\n'
      '② 课表数据：你主动创建或导入的学期、课程、周次、地点与时间安排，用于展示、提醒、多设备同步和你主动使用的分享功能；\n'
      '③ 日程数据：你通过文字、图片、语音或手动创建并确认保存的个人日程（标题、时间、地点），用于展示、提醒与多设备同步；在「共同空闲」中日程只以「忙碌/空闲」状态参与计算，配对对象看不到日程内容；\n'
      '④ 共同空闲数据：邀请、连接关系和每节课的忙闲结果；\n'
      '⑤ 账户通知：通知标题、正文、业务类型、发送与读取状态，供 App 和网页版收件箱展示；\n'
      '⑥ 安全与会话信息：登录刷新令牌、受限功能会话凭证以及必要的访问时间、请求大小、耗时和错误码等安全运行日志。\n\n'
      '二、教务账号与密码\n'
      '我们不接收、不传输、不存储你的教务系统账号和密码。你在网页或 App 内登录学校系统时，账号密码只经过你的设备与学校系统服务器；我们的服务器没有接收教务密码的接口。\n\n'
      '三、截图、表格与页面 AI 导入\n'
      'AI 解析仅在你主动选择文件或主动确认解析后触发，每用户每天限 10 次。\n\n'
      '① 课表截图：截图会经服务器转交第三方大模型小米 MiMo 作一次识别。截图无法在上传前可靠自动遮盖身份信息，请先裁掉姓名、学号等与课表无关的区域；\n'
      '② Excel/CSV 表格：XLSX、XLS、CSV 文件只读解析。服务器只提取有界的单元格文本，并对姓名、学号、手机号等常见身份信息脱敏后，再交给 MiMo；\n'
      '③ 课表页面兜底解析：仅在本地解析失败且你主动确认后使用。设备端先移除常见身份字段和长数字串，服务器收到后再次脱敏，只提取课表结构用于一次解析；\n'
      '④ 不留存原始内容：原始文件、页面原文、提取文本和模型响应不写入数据库或业务日志，处理完成后从内存丢弃；日志只记录文件类型、大小、数量、耗时和错误码等运行元数据。\n\n'
      '不使用相应的 AI 导入功能，就不会上传上述截图、表格或页面内容。\n\n'
      '四、AI 日程与文字、图片、语音录入\n'
      'AI 日程仅在你主动输入文字、选择图片（拍照或相册）或按住麦克风说话后触发，每用户每天限 30 次。语音录入目前仅在 Android App 提供，网页版支持文字与图片。\n\n'
      '① 语音即转即删：录音在你松手后上传服务器一次，经小米 MiMo 语音识别转写为文字；音频与转写文本不写入数据库、不写入日志，识别完成即从内存丢弃；\n'
      '② 图片与文字：你选择的图片经压缩后上传服务器一次，与输入的文字一样交由小米 MiMo 识别为结构化日程；图片、文字与识别结果不写入数据库、不写入日志，识别完成即从内存丢弃。选择图片前页面会请你确认已核对内容；\n'
      '③ 文本理解：转写文本、输入文字或图片识别结果，经与本政策第三节相同的身份脱敏规则处理后，交由小米 MiMo 大模型提取时间、地点与事项。为正确理解「周三」「下周」「那节课」，请求会附带当天日期、你当前学期的周次与课程名列表作为上下文，除此之外不包含任何身份信息；\n'
      '④ 确认后才保存：识别结果在预览页展示，由你确认或修改后才保存为日程；\n'
      '⑤ 麦克风权限：仅语音录入需要，拒绝授权不影响文字与图片输入及其他全部功能。\n\n'
      '五、共同空闲与用户名搜索\n'
      '共同空闲用于连接同学、朋友或小组成员的课表，查找双方都没有课程的节次。你可以直接输入用户名发送邀请，也可以输入至少 2 个字符进行用户名开头匹配；每次最多返回 5 个结果，结果中只包含用户名，不提供邮箱、用户编号或其他账号资料。搜索和邀请接口均设置频率限制。\n\n'
      '你也可以生成 8 位、15 分钟有效的邀请码。服务器只保存邀请码的不可逆摘要，原码只在生成方当前页面中短暂显示。对方明确接受用户名邀请或主动输入邀请码后才建立连接。\n\n'
      '连接建立后，服务器只向连接双方提供每节课的忙闲结果和用户名，不提供课程名、教师、教室或备注。邀请可撤回或拒绝，连接可由任一方随时解除，解除后立即停止共享。\n\n'
      '六、通知、更新提醒与第三方 SDK\n'
      '通知仅在你授权后启用。Android App 使用杭州阿里云智能科技有限公司提供的 EMAS 移动推送 SDK，网页版使用浏览器 Web Push；相关服务可能按其规则处理设备标识、应用信息、网络信息和推送日志。拒绝通知不影响课表基本功能。\n\n'
      '新版本默认通过一条账户通知或系统通知告知，由你主动打开详情并决定是否更新，不因一般功能更新强制遮挡课表界面。账户通知可以在收件箱中标记已读或删除。\n\n'
      '七、设备权限\n'
      '网络权限用于登录、导入和同步；通知、开机恢复提醒、闹钟、唤醒锁、振动和前台服务能力用于你主动开启的提醒与推送。文件通过系统选择器获得单个文件的一次性访问授权，不申请读写全部外部存储，也不索取通讯录、定位、相机或蓝牙权限。\n'
      '麦克风仅在你于 Android App「AI 日程」页按住说话时用于录音，录音实时转写后即删、不保存音频；网页版不申请麦克风权限。选择图片时由系统文件选择器或浏览器相机接管，我们同样只获得你选中的那一张图片。拒绝授权不影响文字输入与其他功能。\n\n'
      '八、远程功能与安全\n'
      '服务器签名的功能清单可以启用当前 APK 已允许的原生入口或受限网页模块，但不能下载并执行新的 Dart 或原生代码。原生功能使用账号访问令牌；网页模块使用仅限单个功能、15 分钟有效的会话凭证。\n\n'
      '不同账号的数据按用户标识隔离，服务端对每次读取和写入重新鉴权。共同空闲、通知和课表接口只返回当前账号有权访问的数据。\n\n'
      '九、保存、共享与跨设备同步\n'
      '账号、课表与日程数据存储于境内的阿里云服务器，用于多设备同步和你主动使用的分享功能，仅在提供功能及安全审计所需期限内保存。网页版会在本机保存当前账号的课表，供断网时查看，退出登录时清除这份缓存。我们不出售个人信息；除上述云服务基础设施、小米 MiMo及推送服务（处理范围以本政策为限），以及法律法规要求外，不向无关第三方共享。\n\n'
      '账号注销后，除依法需要保留的安全日志外，其余关联数据会删除。\n\n'
      '十、你的权利\n'
      '你可以退出登录、关闭通知、删除账户通知、撤销邀请或连接，并通过 z40681992@163.com 联系管理员查询、更正或删除账号及云端数据。\n\n'
      '十一、政策更新\n'
      '政策发生重大变化时，我们会通过 App 内提示、网站公告或推送告知，并在法律要求或处理目的发生重大变化时请求你重新同意。\n\n'
      '本次第 7 版把 App、网页版与官网的政策统一为同一份文本：补充网页版 AI 日程的文字与图片录入说明，订正共同空闲的用户名搜索描述，并合并此前分散的说明。本次不新增处理目的、不新增系统权限，已同意用户无需再次确认。\n\n'
);

/// 教务系统目录条目（远程下发，与 modules 同通道签名，加学校不用发版）。
class SchoolDirectoryEntry {
  const SchoolDirectoryEntry({
    required this.name,
    required this.url,
    required this.system,
  });

  final String name;
  final String url;
  final String system;

  factory SchoolDirectoryEntry.fromJson(Map<String, dynamic> json) {
    final name = _boundedString(json['name'], 80);
    final url = _boundedString(json['url'], 2048);
    final system = _boundedString(json['system'], 32);
    final parsed = Uri.tryParse(url);
    if (name.isEmpty ||
        parsed == null ||
        parsed.scheme != 'https' ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasFragment) {
      throw const FormatException('Invalid school directory entry');
    }
    return SchoolDirectoryEntry(name: name, url: url, system: system);
  }
}

class RemoteFeatureModule {
  const RemoteFeatureModule({
    required this.id,
    required this.title,
    required this.description,
    required this.entryUrl,
    required this.placements,
    required this.capabilities,
    required this.minBuild,
    required this.maxBuild,
    required this.rolloutPercent,
    required this.priority,
    this.requiresLogin = true,
    this.badge = '',
    this.audience = RemoteFeatureAudience.all,
  });

  final String id;
  final String title;
  final String description;
  final Uri entryUrl;
  final Set<RemoteFeaturePlacement> placements;
  final Set<RemoteFeatureCapability> capabilities;
  final int minBuild;
  final int maxBuild;
  final int rolloutPercent;
  final int priority;
  final bool requiresLogin;
  final String badge;
  final RemoteFeatureAudience audience;

  factory RemoteFeatureModule.fromJson(Map<String, dynamic> json) {
    final id = _boundedString(json['id'], 64);
    final title = _boundedString(json['title'], 80);
    final description = _boundedString(json['description'], 240);
    final badge = _boundedString(json['badge'] ?? '', 24, allowEmpty: true);
    final entry = Uri.tryParse(_boundedString(json['entryUrl'], 2048));
    final minBuild = json['minBuild'];
    final maxBuild = json['maxBuild'];
    final rolloutPercent = json['rolloutPercent'];
    final priority = json['priority'];
    final requiresLogin = json['requiresLogin'];
    final audience = RemoteFeatureAudience.parse(json['audience']);
    final rawPlacements = json['placements'];
    final rawCapabilities = json['capabilities'];
    if (!RegExp(r'^[a-z][a-z0-9_-]{2,63}$').hasMatch(id) ||
        entry == null ||
        !isTrustedRemotePage(entry) ||
        minBuild is! int ||
        maxBuild is! int ||
        minBuild < 1 ||
        maxBuild < minBuild ||
        rolloutPercent is! int ||
        rolloutPercent < 0 ||
        rolloutPercent > 100 ||
        priority is! int ||
        priority < -1000 ||
        priority > 1000 ||
        requiresLogin is! bool ||
        rawPlacements is! List ||
        rawPlacements.isEmpty ||
        rawPlacements.length > 4 ||
        rawCapabilities is! List ||
        rawCapabilities.length > 6) {
      throw const FormatException('Invalid remote feature');
    }
    return RemoteFeatureModule(
      id: id,
      title: title,
      description: description,
      badge: badge,
      entryUrl: entry,
      minBuild: minBuild,
      maxBuild: maxBuild,
      rolloutPercent: rolloutPercent,
      priority: priority,
      requiresLogin: requiresLogin,
      audience: audience,
      placements: Set.unmodifiable(rawPlacements
          .map((value) => RemoteFeaturePlacement.parse(value as String))),
      capabilities: Set.unmodifiable(rawCapabilities
          .map((value) => RemoteFeatureCapability.parse(value as String))),
    );
  }
}

class RemoteFeatureManifest {
  const RemoteFeatureManifest({
    required this.revision,
    required this.issuedAt,
    required this.expiresAt,
    required this.privacyPolicy,
    required this.modules,
    this.schoolDirectory,
    this.stale = false,
  });

  final int revision;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final RemotePrivacyPolicy privacyPolicy;
  final List<RemoteFeatureModule> modules;

  /// 远程下发的学校目录（可空；空时客户端用内置种子名单）。
  final List<SchoolDirectoryEntry>? schoolDirectory;
  final bool stale;

  static final bundled = RemoteFeatureManifest(
    revision: 0,
    issuedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    privacyPolicy: bundledPrivacyPolicy,
    modules: const [],
  );

  factory RemoteFeatureManifest.fromPayload(
    Map<String, dynamic> json, {
    required int appBuild,
    required DateTime now,
    bool allowExpired = false,
  }) {
    int integer(String key) {
      final value = json[key];
      if (value is! int) throw const FormatException('Invalid integer');
      return value;
    }

    final schema = integer('schema');
    final revision = integer('revision');
    final minBuild = integer('minBuild');
    final maxBuild = integer('maxBuild');
    final issuedAt = DateTime.fromMillisecondsSinceEpoch(
      integer('issuedAt') * 1000,
      isUtc: true,
    );
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      integer('expiresAt') * 1000,
      isUtc: true,
    );
    final expired = !now.toUtc().isBefore(expiresAt);
    final rawPolicy = json['privacyPolicy'];
    final rawModules = json['modules'];
    if (schema != 1 ||
        revision < 1 ||
        minBuild < 1 ||
        maxBuild < minBuild ||
        appBuild < minBuild ||
        appBuild > maxBuild ||
        issuedAt.isAfter(now.toUtc().add(const Duration(minutes: 5))) ||
        expiresAt.difference(issuedAt) > const Duration(days: 45) ||
        (expired && !allowExpired) ||
        rawPolicy is! Map<String, dynamic> ||
        rawModules is! List ||
        rawModules.length > 24) {
      throw const FormatException('Incompatible remote manifest');
    }

    final modules = <RemoteFeatureModule>[];
    final ids = <String>{};
    for (final raw in rawModules) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid module record');
      }
      final module = RemoteFeatureModule.fromJson(raw);
      if (!ids.add(module.id)) throw const FormatException('Duplicate module');
      if (appBuild >= module.minBuild && appBuild <= module.maxBuild) {
        modules.add(module);
      }
    }
    modules.sort((a, b) => b.priority.compareTo(a.priority));
    final policy = RemotePrivacyPolicy.fromJson(rawPolicy);
    if (policy.revision < bundledPrivacyPolicy.revision) {
      throw const FormatException('Privacy policy rollback');
    }
    // 学校目录为可选字段：缺省/为空数组时客户端回落内置名单；
    // 单条非法不致命（跳过），但整体类型错误视为清单损坏。
    List<SchoolDirectoryEntry>? schoolDirectory;
    final rawDirectory = json['schoolDirectory'];
    if (rawDirectory != null) {
      if (rawDirectory is! List || rawDirectory.length > 2000) {
        throw const FormatException('Invalid school directory');
      }
      final entries = <SchoolDirectoryEntry>[];
      for (final raw in rawDirectory) {
        if (raw is! Map<String, dynamic>) continue;
        try {
          entries.add(SchoolDirectoryEntry.fromJson(raw));
        } on FormatException {
          // 单条非法（如 http URL）跳过，不影响其余
        }
      }
      if (entries.isNotEmpty) schoolDirectory = List.unmodifiable(entries);
    }
    return RemoteFeatureManifest(
      revision: revision,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      privacyPolicy: policy,
      modules:
          List.unmodifiable(expired ? const <RemoteFeatureModule>[] : modules),
      schoolDirectory: schoolDirectory,
      stale: expired,
    );
  }

  RemoteFeatureManifest forInstallation(String installationId) {
    final visible = modules.where((module) {
      if (module.rolloutPercent >= 100) return true;
      if (module.rolloutPercent <= 0) return false;
      return stableRolloutBucket('$installationId:${module.id}') <
          module.rolloutPercent;
    }).toList(growable: false);
    return RemoteFeatureManifest(
      revision: revision,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      privacyPolicy: privacyPolicy,
      modules: List.unmodifiable(visible),
      schoolDirectory: schoolDirectory,
      stale: stale,
    );
  }

  RemoteFeatureModule? moduleById(String id) {
    for (final module in modules) {
      if (module.id == id) return module;
    }
    return null;
  }

  List<RemoteFeatureModule> modulesAt(RemoteFeaturePlacement placement) =>
      modules.where((module) => module.placements.contains(placement)).toList();
}

bool isTrustedRemotePage(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (!uri.hasPort || uri.port == 443) &&
    uri.host.toLowerCase() == 'hanshang.seanyan.store' &&
    uri.path.startsWith('/web/modules/');

int stableRolloutBucket(String value) {
  // FNV-1a gives a stable local bucket without sending an identifier to the
  // feature manifest endpoint.
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % 100;
}

String _boundedString(Object? value, int max, {bool allowEmpty = false}) {
  if (value is! String ||
      value.length > max ||
      (!allowEmpty && value.isEmpty)) {
    throw const FormatException('Invalid string');
  }
  return value;
}
