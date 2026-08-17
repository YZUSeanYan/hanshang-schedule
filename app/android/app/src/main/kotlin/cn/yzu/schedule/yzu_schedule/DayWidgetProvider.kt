package cn.yzu.schedule.yzu_schedule

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews

/**
 * 「日视图」桌面小组件（4x2）：App 风格马卡龙色块，节次+时间+课程+地点。
 * 数据契约：day_courses_json = [{sec, time, name, loc, color, colorIndex}, ...]
 */
class DayWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) {
            updateOne(context, appWidgetManager, id)
        }
    }

    companion object {
        private val ROW_IDS = intArrayOf(
            R.id.day_row1, R.id.day_row2, R.id.day_row3, R.id.day_row4,
            R.id.day_row5, R.id.day_row6, R.id.day_row7, R.id.day_row8
        )
        private val TEXT_IDS = intArrayOf(
            R.id.day_row1_text, R.id.day_row2_text, R.id.day_row3_text, R.id.day_row4_text,
            R.id.day_row5_text, R.id.day_row6_text, R.id.day_row7_text, R.id.day_row8_text
        )

        fun updateOne(
            context: Context,
            appWidgetManager: AppWidgetManager,
            widgetId: Int
        ) {
            val title = WidgetData.getString(context, "day_title", "日视图")
            val items = WidgetData.getJsonArray(context, "day_courses_json")

            val views = RemoteViews(context.packageName, R.layout.day_widget)
            views.setTextViewText(R.id.day_title, title)

            for (i in ROW_IDS.indices) {
                if (i < items.length()) {
                    val item = items.getJSONObject(i)
                    val sec = item.optString("sec")
                    val time = item.optString("time")
                    val sub = buildString {
                        if (sec.isNotEmpty()) { append(sec); append(" ") }
                        append(time)
                        val loc = item.optString("loc")
                        if (loc.isNotEmpty()) { append(" · "); append(loc) }
                    }
                    WidgetData.fillCourseBlock(
                        views, ROW_IDS[i], TEXT_IDS[i],
                        item.optString("name"), sub, "",
                        WidgetData.colorIndexOf(item, i)
                    )
                } else {
                    WidgetData.hideRow(views, ROW_IDS[i])
                }
            }
            views.setViewVisibility(
                R.id.day_empty, if (items.length() == 0) View.VISIBLE else View.GONE
            )
            views.setOnClickPendingIntent(R.id.day_open_btn, WidgetData.openAppIntent(context))
            views.setOnClickPendingIntent(R.id.day_title, WidgetData.openAppIntent(context))
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
