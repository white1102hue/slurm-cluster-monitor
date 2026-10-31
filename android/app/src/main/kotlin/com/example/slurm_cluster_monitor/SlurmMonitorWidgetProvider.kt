package com.example.slurm_cluster_monitor

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

class SlurmMonitorWidgetProvider : HomeWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        // HomeWidget sends this even with zero ordinary desktop widget IDs.
        // Publish from the monitoring process, where these preferences are fresh.
        if (intent.action == AppWidgetManager.ACTION_APPWIDGET_UPDATE ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            runCatching {
                val data = HomeWidgetPlugin.getData(context)
                XiaomiWidgetStore.publish(context, WidgetSnapshot.read(data).toString(),
                    data.getBoolean("slurm_widget_refreshing", false))
                XiaomiSlurmWidgetProvider.updateAll(context)
            }.onFailure {
                android.util.Log.w("SlurmWidget", "Unable to update the Xiaomi widget snapshot")
            }
        }
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val manager = AppWidgetManager.getInstance(context)
            onUpdate(context, manager, manager.getAppWidgetIds(android.content.ComponentName(context, javaClass)),
                HomeWidgetPlugin.getData(context))
            return
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
        val snapshot = WidgetSnapshot.read(data)
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.slurm_widget_layout)
            val palette = WidgetPalette.read(data)
            views.setInt(R.id.widget_root, "setBackgroundResource", palette.background)
            views.setTextColor(R.id.widget_title, palette.primary)
            val refreshing = data.getBoolean("slurm_widget_refreshing", false)
            views.setTextViewText(R.id.widget_refresh, if (refreshing) "…" else "↻")
            views.setContentDescription(R.id.widget_refresh, if (refreshing) "正在刷新作业" else "刷新作业")
            views.setTextColor(R.id.widget_refresh, palette.secondary)
            views.setTextColor(R.id.node_summary, palette.text)
            views.setTextColor(R.id.widget_time, palette.muted)
            views.setTextColor(R.id.empty_jobs, palette.muted)
            views.setTextViewText(R.id.node_summary, snapshot.optString("nodeSummary", "空闲节点 —"))
            val status = snapshot.optString("status", "请打开应用启动监控")
            val offline = snapshot.optInt("offline", 0)
            views.setTextViewText(R.id.widget_time, "${snapshot.optString("timestamp", "尚未刷新")} · $status${if (offline > 0) " · $offline 台离线" else ""}")
            val intent = Intent(context, SlurmWidgetRemoteViewsService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                this.data = Uri.parse("slurm-widget://jobs/$id")
            }
            @Suppress("DEPRECATION")
            views.setRemoteAdapter(R.id.job_list, intent)
            views.setEmptyView(R.id.job_list, R.id.empty_jobs)
            val launch = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val open = PendingIntent.getActivity(context, id, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.widget_refresh,
                HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("slurm-widget://refresh")))
            views.setOnClickPendingIntent(R.id.widget_title, open)
            // Collection fill-in intents require a mutable template with an explicit component.
            val template = PendingIntent.getActivity(context, id + 100000, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            views.setPendingIntentTemplate(R.id.job_list, template)
            views.setViewVisibility(R.id.empty_jobs, if ((snapshot.optJSONArray("running_jobs_json")?.length() ?: 0) == 0) View.VISIBLE else View.GONE)
            manager.updateAppWidget(id, views)
            @Suppress("DEPRECATION")
            manager.notifyAppWidgetViewDataChanged(id, R.id.job_list)
        }
    }
}
