package cn.yzu.schedule.yzu_schedule

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * 「近日课程」桌面小组件（4x2）：今天/明天两列，每列最多 3 个彩色课程块。
 * 数据契约：twoday_json = {left:{head,courses:[{name,colorIndex}]}, right:{...}}
 */
class TwoDayWidgetProvider : AppWidgetProvider() {

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
        private val LEFT_CELLS = intArrayOf(
            R.id.twoday_left_c1, R.id.twoday_left_c2, R.id.twoday_left_c3
        )
        private val RIGHT_CELLS = intArrayOf(
            R.id.twoday_right_c1, R.id.twoday_right_c2, R.id.twoday_right_c3
        )

        fun updateOne(
            context: Context,
            appWidgetManager: AppWidgetManager,
            widgetId: Int
        ) {
            val title = WidgetData.getString(context, "twoday_title", "近日课程")
            val data = WidgetData.getJsonObject(context, "twoday_json")

            val views = RemoteViews(context.packageName, R.layout.twoday_widget)
            views.setTextViewText(R.id.twoday_title, title)

            fillColumn(views, data.optJSONObject("left"), R.id.twoday_left_head, LEFT_CELLS)
            fillColumn(views, data.optJSONObject("right"), R.id.twoday_right_head, RIGHT_CELLS)

            views.setOnClickPendingIntent(R.id.twoday_open_btn, WidgetData.openAppIntent(context))
            views.setOnClickPendingIntent(R.id.twoday_title, WidgetData.openAppIntent(context))
            appWidgetManager.updateAppWidget(widgetId, views)
        }

        private fun fillColumn(
            views: RemoteViews,
            col: JSONObject?,
            headId: Int,
            cellIds: IntArray
        ) {
            if (col == null) {
                views.setTextViewText(headId, "")
                for (id in cellIds) views.setViewVisibility(id, View.GONE)
                return
            }
            views.setTextViewText(headId, col.optString("head"))
            val courses = col.optJSONArray("courses")
            for (j in cellIds.indices) {
                val cellId = cellIds[j]
                if (courses != null && j < courses.length()) {
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
        }
    }
}
