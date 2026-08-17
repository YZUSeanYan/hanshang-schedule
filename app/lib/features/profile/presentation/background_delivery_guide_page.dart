import 'package:flutter/material.dart';

class BackgroundDeliveryGuidePage extends StatelessWidget {
  const BackgroundDeliveryGuidePage({super.key});

  static const _guides = <({String brand, String steps})>[
    (
      brand: '华为 / 荣耀',
      steps: '设置 → 应用和服务 → 应用启动管理 → 找到“邗上课表” → 关闭自动管理，并开启自启动、关联启动、后台活动；再进入多任务界面，下拉应用卡片加锁。',
    ),
    (
      brand: '小米 / Redmi',
      steps: '设置 → 应用设置 → 应用管理 → 邗上课表 → 开启自启动；在省电策略中选“无限制”；打开多任务界面，长按应用卡片并点锁形图标。通知横幅：设置 → 通知与状态栏 → 通知管理 → 邗上课表 → 打开“悬浮通知”；若通知被折叠进“不重要通知”区域，长按该通知并选择“设为重要”。',
    ),
    (
      brand: 'OPPO / 一加 / realme',
      steps: '设置 → 应用 → 自启动管理 → 允许邗上课表自启动及后台运行；在电池用量中关闭后台耗电限制；多任务界面点菜单并选择锁定。',
    ),
    (
      brand: 'vivo / iQOO',
      steps: '设置 → 应用与权限 → 权限管理 → 自启动 → 开启邗上课表；在电池 → 后台耗电管理中允许后台高耗电；多任务界面下滑应用卡片加锁。',
    ),
    (
      brand: '三星',
      steps: '设置 → 电池和设备维护 → 电池 → 后台使用限制 → 从“深度休眠应用”移除邗上课表，并可加入“从不自动休眠的应用”。',
    ),
    (
      brand: '其他 Android',
      steps: '在系统设置中搜索“自启动”“后台运行”“电池优化”，允许邗上课表后台活动并取消电池优化；在多任务页面锁定应用。菜单名称可能随系统版本不同。',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('通知保活设置')), 
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('送达能力说明', style: TextStyle(fontWeight: FontWeight.w700)),
                    SizedBox(height: 8),
                    Text('当前版本使用阿里云自有推送通道。App 正在运行或保留在后台时通常可以接收；如果被系统彻底杀死、强行停止，或厂商省电策略阻止后台活动，通知可能延迟或无法送达。站内通知仍会保留，可在“账户通知”中查看。'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final guide in _guides)
              Card(
                child: ExpansionTile(
                  title: Text(guide.brand),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [Text(guide.steps)],
                ),
              ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '提示：后台锁定只能降低被系统清理的概率，不能形成 100% 送达保证。厂商系统升级后路径可能变化，请以手机实际菜单为准。',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      );
}
