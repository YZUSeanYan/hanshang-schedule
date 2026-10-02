package cn.yzu.schedule.yzu_schedule

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONArray

/**
 * 开机接收器（review R19/R20 重构后）：只负责**清理旧版遗留闹钟**。
 *
 * 旧版链路（本文件曾自研）：读 SharedPreferences 的待提醒列表重挂
 * AlarmManager 闹钟，目标指向自研 NotificationReceiver。问题是这些
 * PendingIntent 与 Flutter 侧 cancel/cancelAll 取消的插件目标不是同一个，
 * 用户在 App 里关闭提醒后旧闹钟照样响，且通知渠道信息丢失。
 *
 * 现在提醒的调度/恢复/取消统一走 flutter_local_notifications 插件链路
 * （ScheduledNotificationBootReceiver 在开机时按插件自己的持久化重挂，
 * 与 Dart 侧 cancel 目标一致）。本接收器只把旧版本可能残留的、指向
 * NotificationReceiver 的闹钟逐个取消，然后清掉遗留缓存。
 *
 * 数据契约（旧版遗留）：SharedPreferences 文件 FlutterSharedPreferences，
 * 键 "flutter.pending_reminders"，值为 JSON 数组 [{"id":1,...}, ...]。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        val raw = prefs.getString("flutter.pending_reminders", null) ?: return
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        try {
            val items = JSONArray(raw)
            for (i in 0 until items.length()) {
                val id = items.getJSONObject(i).optInt("id", -1)
                if (id < 0) continue
                // 重建与旧版完全相同的 PendingIntent 再取消（按 id+目标匹配）
                val legacyIntent = Intent(context, NotificationReceiver::class.java)
                val pendingIntent = PendingIntent.getBroadcast(
                    context, id, legacyIntent,
                    PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
                )
                if (pendingIntent != null) {
                    alarmManager.cancel(pendingIntent)
                    pendingIntent.cancel()
                }
            }
            prefs.edit().remove("flutter.pending_reminders").apply()
        } catch (e: Exception) {
            Log.w("BootReceiver", "legacy alarm cleanup failed", e)
        }
    }
}
