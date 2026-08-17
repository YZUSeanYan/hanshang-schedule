package cn.yzu.schedule.yzu_schedule

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews

/**
 * 「今日课程」桌面小组件（v3）：App 风格——马卡龙圆角课程块 + 加粗名称 + 两行内容。
 * 数据契约：today_courses_json = [{time, name, loc, color, colorIndex}, ...]
 */
class TodayWidgetProvider : AppWidgetProvider() {

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
            R.id.row1, R.id.row2, R.id.row3, R.id.row4, R.id.row5, R.id.row6
        )
        private val TEXT_IDS = intArrayOf(
            R.id.row1_text, R.id.row2_text, R.id.row3_text,
            R.id.row4_text, R.id.row5_text, R.id.row6_text
        )

        fun updateOne(
            context: Context,
            appWidgetManager: AppWidgetManager,
            widgetId: Int
        ) {
            val title = WidgetData.getString(context, "today_title", "邗上课表")
            val items = WidgetData.getJsonArray(context, "today_courses_json")

            val views = RemoteViews(context.packageName, R.layout.today_widget)
            views.setTextViewText(R.id.title, title)

            for (i in ROW_IDS.indices) {
                if (i < items.length()) {
                    val item = items.getJSONObject(i)
                    WidgetData.fillCourseBlock(
                        views, ROW_IDS[i], TEXT_IDS[i],
                        item.optString("name"),
                        item.optString("time"),
                        item.optString("loc"),
                        WidgetData.colorIndexOf(item, i)
                    )
                } else {
                    WidgetData.hideRow(views, ROW_IDS[i])
                }
            }
            views.setViewVisibility(
                R.id.empty_hint, if (items.length() == 0) View.VISIBLE else View.GONE
            )
            views.setOnClickPendingIntent(R.id.open_btn, WidgetData.openAppIntent(context))
            views.setOnClickPendingIntent(R.id.title, WidgetData.openAppIntent(context))
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
