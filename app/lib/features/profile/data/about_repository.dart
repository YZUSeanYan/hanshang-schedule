import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/about_media_cache.dart';

/// 「关于邗上课表」页内容。
class AboutContent {
  const AboutContent({
    required this.displayName,
    required this.intro,
    required this.websiteUrl,
    required this.avatarMedia,
    required this.paymentQrMedia,
    required this.icpBeian,
  });

  factory AboutContent.fromJson(Map<String, dynamic> json) => AboutContent(
        displayName: json['display_name'] as String? ?? '邗上课表',
        intro: json['intro'] as String? ?? '',
        websiteUrl: json['website_url'] as String? ?? '',
        avatarMedia: json['avatar_media'] as String? ?? '',
        paymentQrMedia: json['payment_qr_media'] as String? ?? '',
        icpBeian: json['icp_beian'] as String? ?? '',
      );

  final String displayName;
  final String intro;
  final String websiteUrl;
  final String avatarMedia;
  final String paymentQrMedia;
  final String icpBeian;
}

/// 关于页数据仓库（2026-10-01 用户反馈：头像和关于页每次都完整重载）。
///
/// - JSON 内容很小，实例内保留最后一次成功结果：重进页面先即时渲染，
///   由页面决定是否静默刷新；
/// - 头像/收款码图片按内容摘要文件名落盘缓存（见 [AboutMediaCache]），
///   命中后零网络请求，应用重启也不重新下载。
class AboutRepository {
  AboutRepository(this._dio, this._media);

  final Dio _dio;
  final AboutMediaCache _media;

  AboutContent? _last;

  AboutContent? get cached => _last;

  Future<AboutContent> load() async {
    final response =
        await _dio.get<Map<String, dynamic>>('/api/about');
    final content = AboutContent.fromJson(
        response.data!['data'] as Map<String, dynamic>);
    _last = content;
    return content;
  }

  /// 头像本地文件；未配置头像或下载失败返回 null（页面回退首字母头像）。
  Future<File?> avatarFile() async {
    final name = _last?.avatarMedia ?? '';
    if (name.isEmpty) return null;
    try {
      return await _media.file(name);
    } catch (_) {
      return null;
    }
  }

  /// 收款码本地文件；未配置返回 null，网络失败抛异常（页面显示重试）。
  Future<File> paymentQrFile() async {
    final name = _last?.paymentQrMedia ?? '';
    if (name.isEmpty) throw StateError('作者还没有配置收款码');
    return _media.file(name);
  }
}

final aboutRepositoryProvider = Provider<AboutRepository>(
  (ref) => AboutRepository(
    ref.read(dioProvider),
    ref.read(aboutMediaCacheProvider),
  ),
);
