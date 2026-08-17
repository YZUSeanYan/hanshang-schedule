package cn.yzu.schedule.yzu_schedule

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat

/**
 * 闹钟到点后的通知展示接收器（配合 BootReceiver 的重启重挂链路）。
 * App 进程存活时由 flutter_local_notifications 直接展示，用不到这里；
 * 只有重启后、App 未启动过的情况下才由本接收器发通知。
 */
class NotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 渠道与 Dart 侧保持一致（已存在则创建是幂等操作）
        manager.createNotificationChannel(
            NotificationChannel(
                "class_reminders", "上课提醒", NotificationManager.IMPORTANCE_HIGH
            )
        )
        val notification = NotificationCompat.Builder(context, "class_reminders")
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(intent.getStringExtra("title") ?: "上课提醒")
            .setContentText(intent.getStringExtra("body") ?: "")
            .setAutoCancel(true)
            .build()
        manager.notify(intent.getIntExtra("id", 0), notification)
    }
}
