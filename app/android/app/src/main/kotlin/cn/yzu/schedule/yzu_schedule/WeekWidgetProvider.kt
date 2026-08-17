package cn.yzu.schedule.yzu_schedule

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews

/**
 * 「一周课程」桌面小组件（4x2）：7 列网格，每列最多 3 个彩色课程块。
 * 数据契约：week_grid_json = [{head:"一", courses:[{name,colorIndex}]}, ...]
 */
class WeekWidgetProvider : AppWidgetProvider() {

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
        private val HEAD_IDS = intArrayOf(
            R.id.wcol1_head, R.id.wcol2_head, R.id.wcol3_head, R.id.wcol4_head,
            R.id.wcol5_head, R.id.wcol6_head, R.id.wcol7_head
        )
        private val CELL_IDS = arrayOf(
            intArrayOf(R.id.wcol1_c1, R.id.wcol1_c2, R.id.wcol1_c3),
            intArrayOf(R.id.wcol2_c1, R.id.wcol2_c2, R.id.wcol2_c3),
            intArrayOf(R.id.wcol3_c1, R.id.wcol3_c2, R.id.wcol3_c3),
            intArrayOf(R.id.wcol4_c1, R.id.wcol4_c2, R.id.wcol4_c3),
            intArrayOf(R.id.wcol5_c1, R.id.wcol5_c2, R.id.wcol5_c3),
            intArrayOf(R.id.wcol6_c1, R.id.wcol6_c2, R.id.wcol6_c3),
            intArrayOf(R.id.wcol7_c1, R.id.wcol7_c2, R.id.wcol7_c3),
        )

        fun updateOne(
            context: Context,
            appWidgetManager: AppWidgetManager,
            widgetId: Int
        ) {
            val title = WidgetData.getString(context, "week_title", "一周课程")
            val columns = WidgetData.getJsonArray(context, "week_grid_json")

            val views = RemoteViews(context.packageName, R.layout.week_widget)
            views.setTextViewText(R.id.week_title, title)

            for (i in HEAD_IDS.indices) {
                if (i < columns.length()) {
                    val col = columns.getJSONObject(i)
                    views.setTextViewText(HEAD_IDS[i], col.optString("head"))
                    val courses = col.getJSONArray("courses")
                    for (j in 0 until 3) {
                        val cellId = CELL_IDS[i][j]
                        if (j < courses.length()) {
                            val c = courses.getJSONObject(j)
                            views.setViewVisibility(cellId, View.VISIBLE)
                            views.setInt(
                                cellId, "setBackgroundResource",
                                WidgetData.COURSE_BGS[WidgetData.colorIndexOf(c, j) % 10]
                            )
                            views.setTextViewText(cellId, c.optString("name"))
                        } else {
                            views.setViewVisibility(cellId, View.GONE)
                        }
                    }
                } else {
                    views.setTextViewText(HEAD_IDS[i], "")
                    for (j in 0 until 3) views.setViewVisibility(CELL_IDS[i][j], View.GONE)
                }
            }
            views.setOnClickPendingIntent(R.id.week_open_btn, WidgetData.openAppIntent(context))
            views.setOnClickPendingIntent(R.id.week_title, WidgetData.openAppIntent(context))
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
