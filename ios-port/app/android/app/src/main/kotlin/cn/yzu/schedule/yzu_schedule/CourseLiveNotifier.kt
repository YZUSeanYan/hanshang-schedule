package cn.yzu.schedule.yzu_schedule

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * 上课实时通知（灵动岛 / Live Update）。
 *
 * 课程进行中显示常驻进度通知；Android 16+（API 36）附加 promoted ongoing
 * 标记，系统会把它提升到屏幕上方 / 灵动岛胶囊展示。
 * 支持厂商（用户告知）：原生 Android 16、ColorOS 16、小米 HyperOS 3.0.300、
 * 荣耀 MagicOS 10 及以上。
 */
object CourseLiveNotifier {
    private const val CHANNEL_ID = "course_live"
    private const val NOTIFICATION_ID = 900001

    fun ensureChannel(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID, "上课实时状态", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "上课期间在屏幕上方/灵动岛显示进行中课程"
                setShowBadge(false)
            }
        )
    }

    /** 更新/创建上课中通知 */
    fun update(
        context: Context,
        title: String,
        text: String,
        progress: Int,
        max: Int,
        shortText: String
    ) {
        ensureChannel(context)
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        if (Build.VERSION.SDK_INT >= 36) {
            // Android 16 Live Update：反射调用 promoted ongoing（API 名厂商间有差异，
            // 反射兜底：setRequestPromotedOngoing / setPromoted 依次尝试）
            val native = Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setProgress(max, progress, false)
                .setContentIntent(pendingIntent)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
            for (name in listOf("setRequestPromotedOngoing", "setPromoted")) {
                try {
                    Notification.Builder::class.java
                        .getMethod(name, Boolean::class.javaPrimitiveType)
                        .invoke(native, true)
                    break
                } catch (_: Exception) {}
            }
            try {
                Notification.Builder::class.java
                    .getMethod("setShortCriticalText", CharSequence::class.java)
                    .invoke(native, shortText)
            } catch (_: Exception) {}
            manager.notify(NOTIFICATION_ID, native.build())
        } else {
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setProgress(max, progress, false)
                .setContentIntent(pendingIntent)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .build()
            manager.notify(NOTIFICATION_ID, notification)
        }
    }

    fun cancel(context: Context) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }
}
