/**
 * 邗上课表 Watch - BLE 课表接收模块（主动 read 模式）
 * 手机 App 开启 GATT Server 广播，手表作为 GATT Client 循环 read 分片。
 *
 * 分片协议（手机端 ↔ 手表端约定）：
 *   每帧: [seq:1B][len:1B][data...]   （seq 从 0 递增，len ≤ 180）
 *   结束帧: seq=0xFF（len=0）
 * 手机端 onReadRequested 每次返回下一片，read 到 0xFF 帧即完成。
 */
import bluetoothBLE from "@system.bluetooth.ble";

export const SERVICE_UUID = "8F2A0001-0000-1000-8000-00805F9B34FB";
export const CHAR_UUID = "8F2A0002-0000-1000-8000-00805F9B34FB";

function toBytes(buf) {
  if (buf instanceof Uint8Array) return buf;
  if (buf && buf.buffer) return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  return new Uint8Array(0);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * 接收课表快照：扫描 → 连接 → 协商 MTU → 循环 read 组包 → JSON。
 * 返回 Promise<Object>（快照 JSON），失败 reject {message}
 */
export function receiveSnapshot(timeoutMs) {
  return new Promise((resolve, reject) => {
    let scanner = null;
    let gatt = null;
    let foundChar = null;
    let timer = null;
    let chunks = [];
    let done = false;

    const fail = (message) => {
      if (done) return;
      done = true;
      cleanup();
      reject({ message });
    };

    const cleanup = () => {
      if (timer) { clearTimeout(timer); timer = null; }
      try { if (gatt) gatt.close(); } catch (e) {}
      try { if (scanner) scanner.close(); } catch (e) {}
    };

    timer = setTimeout(() => fail("接收超时，请重试"), timeoutMs || 60000);

    /** 循环 read 直到结束帧 */
    const readLoop = () => {
      if (done) return;
      gatt.readCharacteristicValue({
        characteristic: foundChar,
        success: (res) => {
          if (done) return;
          const value = toBytes(res && (res.value != null ? res.value : res.characteristicValue));
          if (value.length < 2) { fail("数据格式错误"); return; }
          const s = value[0];
          const len = value[1];
          if (s === 0xFF) {
            // 结束帧：组包完成
            const total = chunks.reduce((n, c) => n + c.length, 0);
            if (total === 0) { fail("未收到数据"); return; }
            const raw = new Uint8Array(total);
            let off = 0;
            chunks.forEach((c) => { raw.set(c, off); off += c.length; });
            const text = decodeUtf8(raw);
            let json = null;
            try { json = JSON.parse(text); } catch (e) { fail("数据解析失败"); return; }
            done = true;
            cleanup();
            resolve(json);
            return;
          }
          if (s === 0) {
            chunks = [];
          } else if (s !== chunks.length) {
            // 丢帧：重置重收
            chunks = [];
            sleep(80).then(readLoop);
            return;
          }
          chunks.push(value.slice(2, 2 + len));
          sleep(60).then(readLoop);
        },
        fail: (errData, code) => {
          fail("读取失败 code=" + code);
        },
      });
    };

    const connectDevice = (addr, addrType) => {
      gatt = bluetoothBLE.createGattClientDevice(addr, addrType || "UNKNOWN");
      gatt.connect({
        success: () => {
          gatt.setBLEMtuSize({
            mtu: 512,
            success: () => {},
            fail: () => {},
          });
          gatt.getServices({
            success: (res) => {
              const services = (res && res.services) || [];
              for (const s of services) {
                for (const c of (s.characteristics || [])) {
                  const u = String(c.uuid).toLowerCase();
                  if (u.indexOf("8f2a0002") >= 0) {
                    foundChar = c;
                    break;
                  }
                }
                if (foundChar) break;
              }
              if (!foundChar) { fail("未找到课表服务"); return; }
              readLoop();
            },
            fail: () => fail("服务发现失败"),
          });
        },
        fail: () => fail("连接失败，请在手机上确认已开始发送"),
      });
    };

    scanner = bluetoothBLE.createScanner();
    scanner.startBLEScan({
      filters: [{ serviceUuid: SERVICE_UUID }],
      options: { dutyMode: 2 }, // SCAN_MODE_LOW_LATENCY
      success: () => {},
      fail: () => fail("蓝牙扫描失败，请确认已开启蓝牙"),
    });
    scanner.subscribeBLEDeviceFind({
      callback: (res) => {
        if (done || gatt) return;
        const addr = res && res.deviceId;
        if (!addr) return;
        try { scanner.stopBLEScan({}); } catch (e) {}
        connectDevice(addr, res.addressType);
      },
    });
  });
}

/** UTF-8 手动解码（TextDecoder 在 Vela 环境不可用时） */
function decodeUtf8(bytes) {
  let out = "";
  let i = 0;
  while (i < bytes.length) {
    const b = bytes[i];
    if (b < 0x80) {
      out += String.fromCharCode(b);
      i++;
    } else if (b < 0xE0) {
      out += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if (b < 0xF0) {
      out += String.fromCharCode(((b & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else {
      const cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      out += String.fromCodePoint(cp);
      i += 4;
    }
  }
  return out;
}
