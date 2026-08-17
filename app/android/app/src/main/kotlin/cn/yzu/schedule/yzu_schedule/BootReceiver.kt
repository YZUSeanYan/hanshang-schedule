package cn.yzu.schedule.yzu_schedule

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONArray

/**
 * 开机自启接收器：手机重启后 AlarmManager 里的闹钟会被系统清空，
 * 这里读取 Dart 侧写入 SharedPreferences 的待提醒列表，重新挂闹钟。
 *
 * 数据契约（与 reminder_service.dart 一致）：
 * SharedPreferences 文件 FlutterSharedPreferences（shared_preferences 插件约定），
 * 键 "flutter.pending_reminders"，值为 JSON 数组：
 * [{"id":1,"title":"...","body":"...","time":1757000000000}, ...]
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        val raw = prefs.getString("flutter.pending_reminders", null) ?: return
        val now = System.currentTimeMillis()
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        val items = JSONArray(raw)
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val time = item.getLong("time")
            if (time <= now) continue // 已过期的不重挂
            val notifyIntent = Intent(context, NotificationReceiver::class.java).apply {
                putExtra("id", item.getInt("id"))
                putExtra("title", item.getString("title"))
                putExtra("body", item.getString("body"))
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                item.getInt("id"),
                notifyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            // 非精确闹钟：不需要特殊权限，Doze 下也能触发
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, time, pendingIntent
            )
        }
    }
}
