package com.example.slurm_cluster_monitor

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import android.util.LruCache
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject

class SlurmWidgetRemoteViewsService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = JobFactory(applicationContext)
}

class JobFactory(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
    private var jobs = JSONArray()
    private var palette = WidgetPalette.read(HomeWidgetPlugin.getData(context))
    private val rings = LruCache<String, Bitmap>(32)
    private var clusterColors = emptyMap<String, Int>()
    override fun onCreate() { onDataSetChanged() }
    override fun onDataSetChanged() {
        palette = WidgetPalette.read(HomeWidgetPlugin.getData(context))
        jobs = WidgetSnapshot.read(HomeWidgetPlugin.getData(context)).optJSONArray("running_jobs_json") ?: JSONArray()
        clusterColors = WidgetPalette.resolveServerColors(jobs)
    }
    override fun getCount(): Int = jobs.length()
    override fun getViewAt(position: Int): RemoteViews? {
        val job = jobs.optJSONObject(position) ?: return null
        return RemoteViews(context.packageName, R.layout.slurm_widget_item).apply {
            val serverColor = clusterColors[WidgetPalette.serverKey(job)] ?: palette.secondary
            setInt(R.id.job_row, "setBackgroundColor", palette.serverBackground(serverColor))
            setInt(R.id.job_cluster_mark, "setBackgroundColor", serverColor)
            setTextColor(R.id.job_server, palette.serverForeground(serverColor))
            setTextColor(R.id.job_name, palette.text)
            for (view in listOf(R.id.job_node, R.id.cpu_text, R.id.mem_text)) setTextColor(view, palette.muted)
            setTextColor(R.id.cpu_label, palette.secondary)
            setTextViewText(R.id.job_server, "${job.optString("serverName")}${if (job.optBoolean("stale")) " · 缓存" else ""}")
            setTextViewText(R.id.job_name, job.optString("jobName"))
            setTextViewText(R.id.job_node, "#${job.optString("jobId")} · ${job.optString("nodeList").ifEmpty { "节点待刷新" }}")
            val cpuDetail = job.optString("cpuText", "暂无统计").substringBefore(" · ")
            val memDetail = job.optString("memText", "暂无统计").substringBefore(" · ")
            setTextViewText(R.id.cpu_text, cpuDetail)
            setTextViewText(R.id.mem_text, memDetail)
            val memoryColor = if (job.optInt("memPct") >= 85) Color.parseColor("#B47B19") else palette.primary
            setTextViewText(R.id.cpu_label, "CPU ${percentText(job, "cpu")}")
            setTextViewText(R.id.mem_label, "内存 ${percentText(job, "mem")}")
            setTextColor(R.id.mem_label, memoryColor)
            setImageViewBitmap(R.id.cpu_ring, ringBitmap(job, "cpu", palette.secondary))
            setImageViewBitmap(R.id.mem_ring, ringBitmap(job, "mem", memoryColor))
            setContentDescription(R.id.cpu_ring, "CPU ${percentText(job, "cpu")}，$cpuDetail")
            setContentDescription(R.id.mem_ring, "内存 ${percentText(job, "mem")}，$memDetail")
            setOnClickFillInIntent(R.id.job_row, Intent().putExtra("jobKey", job.optString("key")))
        }
    }
    private fun percentText(job: JSONObject, metric: String): String {
        if (job.has("${metric}PercentText")) return job.optString("${metric}PercentText", "暂无统计")
        // Accept cached rows written by 1.0.0 until their next successful refresh.
        return Regex("[0-9]+(?:\\.[0-9]+)?%").find(job.optString("${metric}Text"))?.value ?: "暂无统计"
    }
    private fun ringBitmap(job: JSONObject, metric: String, color: Int): Bitmap {
        val size = (24 * context.resources.displayMetrics.density).toInt().coerceIn(32, 96)
        val percent = percentText(job, metric)
        val known = percent.endsWith("%")
        val amount = if (known) job.optInt("${metric}Pct").coerceIn(0, 100) else -1
        val key = "$size:$color:${palette.track}:$amount"
        rings.get(key)?.let { return it }
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val stroke = size * 0.12f
        val inset = stroke / 2 + 1
        val bounds = RectF(inset, inset, size - inset, size - inset)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            strokeCap = Paint.Cap.ROUND
            this.color = palette.track
        }
        canvas.drawOval(bounds, paint)
        paint.color = color
        if (known) canvas.drawArc(bounds, -90f, job.optInt("${metric}Pct").coerceIn(0, 100) * 3.6f, false, paint)
        rings.put(key, bitmap)
        return bitmap
    }
    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = (jobs.optJSONObject(position)?.optString("key") ?: "$position").hashCode().toLong()
    override fun hasStableIds(): Boolean = true
    override fun onDestroy() { jobs = JSONArray(); clusterColors = emptyMap(); rings.evictAll() }
}
