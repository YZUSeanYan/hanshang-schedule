package cn.yzu.schedule.yzu_schedule

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.text.SpannableString
import android.text.Spanned
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.graphics.Typeface
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject

/**
 * 小组件共享工具：读取 HomeWidgetPreferences + 打开 App + 马卡龙色块映射。
 * 数据契约由 Dart 侧 WidgetService 写入。
 */
object WidgetData {

    /** 马卡龙课程块背景（与 App 周视图同款 10 色） */
    val COURSE_BGS = intArrayOf(
        R.drawable.widget_course_bg_1, R.drawable.widget_course_bg_2,
        R.drawable.widget_course_bg_3, R.drawable.widget_course_bg_4,
        R.drawable.widget_course_bg_5, R.drawable.widget_course_bg_6,
        R.drawable.widget_course_bg_7, R.drawable.widget_course_bg_8,
        R.drawable.widget_course_bg_9, R.drawable.widget_course_bg_10,
    )

    /** 按系统当前日期生成 yyyy-MM-dd（与 Dart 侧 render_date 契约一致） */
    fun todayKey(): String =
        java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            .format(java.util.Date())

    /**
     * 小组件标题读取（跨午夜诚实提示，review R23）：快照是"渲染时刻"的
     * 静态数据；若渲染日期不是今天，标题追加提示而不是把昨天的课当今天。
     * App 侧（60 秒定时器/数据变化）会尽快重刷消除该状态。
     */
    fun displayTitle(context: Context, key: String, fallback: String): String {
        val title = getString(context, key, fallback)
        val rendered = getString(context, "render_date", "")
        return if (rendered.isNotEmpty() && rendered != todayKey()) {
            "$title（打开 App 更新）"
        } else title
    }

    fun prefs(context: Context) = context.getSharedPreferences(
        "HomeWidgetPreferences", Context.MODE_PRIVATE
    )

    fun getString(context: Context, key: String, fallback: String = ""): String =
        prefs(context).getString(key, fallback) ?: fallback

    fun getJsonArray(context: Context, key: String): JSONArray =
        try { JSONArray(getString(context, key, "[]")) } catch (_: Exception) { JSONArray() }

    fun getJsonObject(context: Context, key: String): JSONObject =
        try { JSONObject(getString(context, key, "{}")) } catch (_: Exception) { JSONObject() }

    /** 点击小组件打开 App 主界面 */
    fun openAppIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** 课程色板索引（widget_service 传 colorIndex，缺省按 0-9 轮询） */
    fun colorIndexOf(item: JSONObject, fallback: Int): Int {
        val idx = item.optInt("colorIndex", -1)
        return if (idx in 0..9) idx else (fallback % 10)
    }

    /** 填充一个课程块：圆角彩色背景 + 加粗名称行 + 小号时间地点行 */
    fun fillCourseBlock(
        views: RemoteViews,
        rowId: Int, textId: Int,
        name: String, time: String, loc: String, colorIndex: Int
    ) {
        views.setViewVisibility(rowId, View.VISIBLE)
        views.setInt(rowId, "setBackgroundResource", COURSE_BGS[colorIndex % 10])
        val sub = if (loc.isNotEmpty()) "$time · $loc" else time
        val text = "$name\n$sub"
        val span = SpannableString(text)
        span.setSpan(StyleSpan(Typeface.BOLD), 0, name.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        span.setSpan(RelativeSizeSpan(1.15f), 0, name.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        span.setSpan(
            RelativeSizeSpan(0.88f),
            name.length + 1, text.length,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
        )
        views.setTextViewText(textId, span)
    }

    fun hideRow(views: RemoteViews, rowId: Int) {
        views.setViewVisibility(rowId, View.GONE)
    }

    fun parseColor(item: JSONObject, index: Int): Int {
        val hex = item.optString("color", "")
        if (hex.startsWith("#")) {
            return try { Color.parseColor(hex) } catch (_: Exception) { 0xFF158A63.toInt() }
        }
        return 0xFF158A63.toInt()
    }
}
