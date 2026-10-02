package cn.yzu.schedule.yzu_schedule

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 旧版自研提醒链路的闹钟目标（review R19/R20 重构后保留为 no-op）。
 *
 * 通知展示已统一由 flutter_local_notifications 插件链路负责：进程存活时
 * 插件直接展示，重启后由 ScheduledNotificationBootReceiver 按插件自己的
 * 持久化重挂。本类保留有两个原因：
 * 1. BootReceiver 清理旧版遗留闹钟时需要以本类名重建 PendingIntent 匹配；
 * 2. 若仍有个别漏网旧闹钟到点，这里静默吞掉，避免用错误的渠道/内容发通知。
 */
class NotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("NotificationReceiver", "legacy alarm fired; ignored (plugin path owns reminders)")
    }
}
