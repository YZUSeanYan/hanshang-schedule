import 'package:flutter/material.dart';

/// 隐私政策全文页（内容与网页版保持一致，生效日期 2026-09-02）。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    const sections = <(String, String)>[
      ('生效日期', '2026 年 9 月 2 日'),
      (
        '我们处理的信息',
        '为提供账号登录、课表导入与同步、课程提醒、账户通知和安全保障，'
            '我们处理用户名、邮箱、加密会话以及你主动创建或导入的学期、课程与时间安排。'
      ),
      (
        '我们不收集的信息',
        '我们不收集、不传输、不存储你的姓名、学号、教务系统账号密码和课表页面原文。'
            '课表导入在你的设备上本地完成；你在 App 或网页内登录学校系统时，'
            '账号密码只存在于你的设备与学校系统之间——我们的服务器没有接收这类信息的接口。'
      ),
      (
        'AI 智能解析',
        '使用「AI 智能解析」时，经你明确确认后，当前课表页面的内容会先在设备上'
            '自动抹除姓名、学号等身份信息，再上传到我们的服务器；服务器收到后立即再次脱敏，'
            '清洗出课程结构后交由第三方大模型（小米 MiMo）解析一次，'
            '解析完成即丢弃——不写入数据库、不写入日志、不用于任何其他目的。'
            '不使用该功能则不会有任何页面上传。'
      ),
      (
        '通知与第三方 SDK',
        '仅在您明确同意并授予通知权限后启用提醒与推送；Android 应用同意后将使用'
            '杭州阿里云智能科技有限公司提供的 EMAS 移动推送 SDK。'
            'SDK 可能按其个人信息处理规则处理设备标识、应用信息、网络信息及推送日志。'
            '拒绝通知不影响基本功能。'
      ),
      (
        '权限、保存和共享',
        '网络权限用于登录与同步，通知权限用于课程和账户消息。'
            '我们不会索取通讯录、定位、相机或麦克风权限。'
            '数据仅在实现功能和安全审计所需期限内保存，不出售个人信息；'
            '除云服务基础设施及依法要求外，不向无关第三方共享。'
      ),
      (
        '激励视频广告',
        '仅在你在「支持作者」中主动确认后，App 才初始化穿山甲广告联盟 SDK 并播放'
            '激励视频广告；广告由第三方投放，其内容不代表本应用立场，'
            '播放过程中 SDK 可能按其隐私政策处理设备标识、应用信息与网络信息。'
            '不观看广告不影响任何功能。'
      ),
      (
        '你的权利',
        '你可以退出登录、关闭通知，并通过 admin@hanshang.seanyan.store 联系管理员'
            '查询、更正或删除账号及云端数据。注销后依法需保留的安全日志除外，'
            '其余关联数据会删除。'
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('邗上课表隐私政策')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (title, body) in sections) ...[
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(body, style: const TextStyle(height: 1.5)),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
