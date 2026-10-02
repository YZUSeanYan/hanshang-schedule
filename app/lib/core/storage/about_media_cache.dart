import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../network/api_client.dart';

/// 「关于页/支持作者」媒体的本地磁盘缓存（2026-10-01 用户反馈：头像和
/// 收款码每次进页面都完整重新下载，浪费服务器流量）。
///
/// 原理：媒体文件名是服务器生成的内容摘要（如 62f3c7d5….jpg），同名即
/// 同内容——所以按文件名落盘后可永久复用，命中时零网络请求。头像与
/// 收款码都走这里；文件放在系统缓存目录，系统空间紧张时可被回收，回收
/// 后最多重新下载一次。
class AboutMediaCache {
  AboutMediaCache(this._dio);

  final Dio _dio;

  static final Map<String, Future<File>> _inFlight = {};

  /// 返回该媒体的本地文件；不存在则从服务器下载后落盘。
  /// 网络失败但磁盘已有旧文件时返回旧文件（陈旧好过空白）。
  Future<File> file(String mediaName) async {
    final dir = await getApplicationCacheDirectory();
    final target = File('${dir.path}/about_media/$mediaName');
    if (await target.exists()) return target;

    final existing = _inFlight[mediaName];
    if (existing != null) return existing;
    final task = _download(mediaName, target)
      ..whenComplete(() => _inFlight.remove(mediaName));
    _inFlight[mediaName] = task;
    return task;
  }

  Future<File> _download(String mediaName, File target) async {
    final url =
        '${AppConfig.apiBaseUrl}/api/about/media/${Uri.encodeComponent(mediaName)}';
    final response = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('媒体内容为空');
    }
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.dl');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path); // 原子落盘，避免半截文件被命中
    return target;
  }
}

final aboutMediaCacheProvider = Provider<AboutMediaCache>(
  (ref) => AboutMediaCache(ref.read(dioProvider)),
);
