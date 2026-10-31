package com.example.slurm_cluster_monitor

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.content.res.Configuration
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import org.json.JSONObject

/** This process only renders cached data; it never creates a Flutter engine or SSH connection. */
class XiaomiSlurmWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "miui.appwidget.action.APPWIDGET_UPDATE") {
            val manager = AppWidgetManager.getInstance(context)
            val owned = manager.getAppWidgetIds(ComponentName(context, javaClass)).toSet()
            val ids = intent.getIntArrayExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS)
                ?.filter { it in owned }?.toIntArray() ?: owned.toIntArray()
            onUpdate(context, manager, ids)
        } else {
            super.onReceive(context, intent)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val snapshot = XiaomiWidgetStore.read(context)
        for (id in ids) manager.updateAppWidget(id, views(context, id, snapshot))
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        if (options.getBoolean("miuiIdChanged") && !options.getBoolean("miuiIdChangedComplete")) {
            val complete = Bundle(options).apply { putBoolean("miuiIdChangedComplete", true) }
            manager.updateAppWidgetOptions(id, complete)
        }
        onUpdate(context, manager, intArrayOf(id))
    }

    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, XiaomiSlurmWidgetProvider::class.java))
            XiaomiSlurmWidgetProvider().onUpdate(context, manager, ids)
        }

        fun views(context: Context, id: Int, snapshot: JSONObject): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.xiaomi_slurm_widget)
            fun count(key: String) = if (snapshot.has(key)) snapshot.optLong(key).coerceAtLeast(0).toString() else "—"
            views.setTextViewText(R.id.xiaomi_counts, "运行 ${count("runningCount")} · 排队 ${count("pendingCount")}")
            views.setTextViewText(R.id.xiaomi_nodes, snapshot.optString("nodeSummary", "空闲节点 —"))
            val first = snapshot.optJSONObject("firstJob")
            val light = context.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK != Configuration.UI_MODE_NIGHT_YES
            val base = context.getColor(R.color.xiaomi_widget_background)
            val accent = first?.optLong("serverColor",
                context.getColor(R.color.xiaomi_widget_accent).toLong())?.toInt() ?: base
            views.setInt(R.id.xiaomi_job_band, "setBackgroundColor",
                WidgetPalette.tintedBackground(base, accent, light))
            views.setInt(R.id.xiaomi_cluster_mark, "setBackgroundColor", accent)
            views.setTextViewText(R.id.xiaomi_job, if (first == null) {
                if (snapshot.has("runningCount")) "暂无运行作业" else "先启动监控"
            } else "${first.optString("jobName")} #${first.optString("jobId")}")
            views.setViewVisibility(R.id.xiaomi_metrics, if (first == null) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.xiaomi_cluster_mark, if (first == null) View.GONE else View.VISIBLE)
            views.setTextViewText(R.id.xiaomi_metrics, if (first == null) "" else {
                "${first.optString("serverName")} · CPU ${first.optString("cpuPercentText", "—")} · 内存 ${first.optString("memPercentText", "—")}"
            })
            val offline = snapshot.optInt("offline")
            val status = snapshot.optString("status", "等待监控数据")
            views.setTextViewText(R.id.xiaomi_time,
                "${snapshot.optString("timestamp", "尚未刷新")} · $status${if (offline > 0) " · $offline 台离线" else ""}")
            val refreshing = snapshot.optBoolean("refreshing")
            views.setTextViewText(R.id.xiaomi_refresh, if (refreshing) "…" else "↻")
            views.setContentDescription(R.id.xiaomi_refresh, if (refreshing) "正在刷新作业" else "刷新作业")
            // The host dispatches this explicit PendingIntent only after a user
            // click. Exposure updates above never wake the monitoring process.
            views.setOnClickPendingIntent(R.id.xiaomi_refresh,
                HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("slurm-widget://refresh")))
            val launch = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val open = PendingIntent.getActivity(context, id + 200000, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.xiaomi_card_root, open)
            views.setOnClickPendingIntent(R.id.xiaomi_job, open)
            return views
        }
    }
}
