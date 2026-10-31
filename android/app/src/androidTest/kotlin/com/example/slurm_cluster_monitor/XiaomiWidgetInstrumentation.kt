package com.example.slurm_cluster_monitor

import android.app.Activity
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.res.Configuration
import android.appwidget.AppWidgetManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.LinearLayout
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Framework-only instrumentation: no external test runner or network dependency. */
class XiaomiWidgetInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val scratch = File(targetContext.cacheDir, "xiaomi-widget-test-${System.nanoTime()}").apply { mkdirs() }
        val testContext = object : ContextWrapper(targetContext) {
            override fun getFilesDir(): File = scratch
            override fun getSharedPreferences(name: String, mode: Int) =
                super.getSharedPreferences("$name.xiaomi-test", mode)
        }
        fun snapshot(n: Int = 2) = JSONObject().apply {
            put("runningCount", n); put("pendingCount", 1)
            put("nodeSummary", "空闲节点 3 / 12")
            put("status", "监控中"); put("timestamp", "14:30:00")
            put("offline", 0); put("timestampEpochMs", 1792996200000L)
            put("password", "must-not-export")
            put("running_jobs_json", JSONArray().put(JSONObject().apply {
                put("serverName", "计算集群"); put("jobId", "42")
                put("jobName", "MOF_adsorption"); put("nodeList", "cn01")
                put("cpuPercentText", "25.0%"); put("memPercentText", "8.5%")
                put("privateKey", "must-not-export"); put("workDir", "/private/work")
                put("serverColor", 0xFF6289C6L)
            }))
        }
        val tests = listOf<Pair<String, () -> Unit>>(
            "manifest" to {
                val info = targetContext.packageManager.getReceiverInfo(
                    ComponentName(targetContext, XiaomiSlurmWidgetProvider::class.java), 128)
                check(info.processName.endsWith(":widgetProvider"))
                check(info.metaData.getBoolean("miuiWidget"))
                check(info.metaData.getInt("miuiWidgetRefreshMinInterval") == 10000)
            },
            "empty_and_private_snapshot" to {
                check(!XiaomiWidgetStore.read(testContext).has("runningCount"))
                XiaomiWidgetStore.publish(testContext, snapshot().toString(), false)
                val saved = XiaomiWidgetStore.read(testContext)
                check(saved.getInt("runningCount") == 2)
                check(!saved.toString().contains("must-not-export"))
                check(!saved.toString().contains("/private/work"))
                check(saved.getLong("timestampEpochMs") == 1792996200000L)
                check(saved.getJSONObject("firstJob").getLong("serverColor") == 0xFF6289C6L)
            },
            "refreshing_and_corrupt_cache" to {
                XiaomiWidgetStore.publish(testContext, snapshot().toString(), true)
                check(XiaomiWidgetStore.read(testContext).getBoolean("refreshing"))
                File(scratch, "xiaomi_widget_snapshot.json").writeText("{broken")
                check(XiaomiWidgetStore.read(testContext).length() == 0)
            },
            "publish_with_no_desktop_widget_ids" to {
                val prefs = HomeWidgetPlugin.getData(testContext)
                prefs.edit().putString("slurm_widget_snapshot", snapshot(7).toString()).commit()
                SlurmMonitorWidgetProvider().onReceive(testContext,
                    Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf()))
                check(XiaomiWidgetStore.read(testContext).getInt("runningCount") == 7)
                prefs.edit().clear().commit()
            },
            "configuration_fence_rejects_late_snapshot" to {
                val prefs = HomeWidgetPlugin.getData(testContext)
                try {
                    prefs.edit().putString("slurm_widget_configuration", "current")
                        .putString("slurm_widget_snapshot", snapshot(9).put("configuration", "old").toString()).commit()
                    check(!WidgetSnapshot.read(prefs).has("running_jobs_json"))
                    val factory = JobFactory(testContext).apply { onCreate() }
                    check(factory.getCount() == 0)
                    factory.onDestroy()
                    SlurmMonitorWidgetProvider().onReceive(testContext,
                        Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf()))
                    check(!XiaomiWidgetStore.read(testContext).has("firstJob"))
                    prefs.edit().putString("slurm_widget_snapshot",
                        snapshot(3).put("configuration", "current").toString()).commit()
                    check(WidgetSnapshot.read(prefs).getInt("runningCount") == 3)
                } finally { prefs.edit().clear().commit() }
            },
            "concurrent_snapshot_writes" to {
                XiaomiWidgetStore.publish(testContext, snapshot().toString(), false)
                val pool = Executors.newFixedThreadPool(4)
                try {
                    val futures = (1..4).map { n -> pool.submit {
                        repeat(15) {
                            XiaomiWidgetStore.publish(testContext, snapshot(n).toString(), n % 2 == 0)
                            check(XiaomiWidgetStore.read(testContext).getInt("runningCount") in 1..4)
                        }
                    }}
                    futures.forEach { it.get(30, TimeUnit.SECONDS) }
                } finally { pool.shutdownNow() }
            },
            "light_card_render" to { render(testContext, snapshot(), false, 1f) },
            "dark_card_and_larger_text" to { render(testContext, snapshot(), true, 1.3f) },
            "desktop_server_tints_light" to { renderDesktop(testContext, false, 1f) },
            "desktop_compact_large_text" to { renderDesktop(testContext, true, 1.3f) },
            "legacy_color_collision_and_package_upgrade" to {
                val rows = JSONArray()
                for (key in listOf("a", "i")) rows.put(JSONObject()
                    .put("key", "$key/1").put("serverName", key).put("jobName", key)
                    .put("serverColor", 0xFF5C9E87L))
                val fixed = WidgetPalette.resolveServerColors(rows)
                check(fixed["a"] != fixed["i"])
                for (index in 0 until rows.length()) rows.getJSONObject(index).remove("serverColor")
                val rebuilt = WidgetPalette.resolveServerColors(rows)
                check(rebuilt["a"] != rebuilt["i"])
                val prefs = HomeWidgetPlugin.getData(testContext)
                prefs.edit().putString("slurm_widget_snapshot",
                    JSONObject().put("running_jobs_json", rows).toString()).commit()
                SlurmMonitorWidgetProvider().onReceive(testContext, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
                val first = XiaomiWidgetStore.read(testContext).getJSONObject("firstJob")
                check(first.getLong("serverColor").toInt() == rebuilt["a"])
                prefs.edit().clear().commit()
            },
        )
        var failures = 0
        try {
            for ((index, test) in tests.withIndex()) {
                val status = Bundle().apply {
                    putString("class", this@XiaomiWidgetInstrumentation.javaClass.name); putString("test", test.first)
                    putInt("current", index + 1); putInt("numtests", tests.size)
                }
                sendStatus(1, status)
                try {
                    test.second()
                    sendStatus(0, status)
                } catch (error: Throwable) {
                    failures++
                    status.putString("stack", error.stackTraceToString())
                    sendStatus(-2, status)
                }
            }
        } finally { scratch.deleteRecursively() }
        finish(if (failures == 0) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putString("stream", "\nNative Xiaomi widget: ${tests.size - failures}/${tests.size} passed, $failures failed\n")
        })
    }

    private fun renderDesktop(context: Context, dark: Boolean, scale: Float) {
        val rows = JSONArray()
        for ((index, color) in listOf(0xFF6289C6L, 0xFF5C9E87L).withIndex()) {
            rows.put(JSONObject().apply {
                put("key", "$index/42"); put("serverName", if (index == 0) "Atlas 计算集群" else "Orion GPU 集群")
                put("jobId", "42"); put("jobName", "geometry_optimization")
                put("nodeList", "cn[001-002]"); put("serverColor", color)
                put("cpuPercentText", "86.3%"); put("memPercentText", "8.5%")
                put("cpuPct", 86); put("memPct", 9)
                put("cpuText", "27.6 / 32 核"); put("memText", "38 GB / 512 GB")
            })
        }
        val prefs = HomeWidgetPlugin.getData(context)
        prefs.edit().putString("slurm_widget_skin", if (dark) "ocean" else "daylight")
            .putString("slurm_widget_snapshot", JSONObject().put("running_jobs_json", rows).toString()).commit()
        var failure: Throwable? = null
        runOnMainSync {
            try {
                val config = Configuration(context.resources.configuration).apply { fontScale = scale }
                val themed = object : ContextWrapper(context.createConfigurationContext(config)) {
                    override fun getSharedPreferences(name: String, mode: Int) = context.getSharedPreferences(name, mode)
                }
                val factory = JobFactory(themed).apply { onCreate() }
                val root = LinearLayout(themed).apply { orientation = LinearLayout.VERTICAL }
                val backgrounds = mutableListOf<Int>()
                for (index in 0..1) {
                    val row = factory.getViewAt(index)!!.apply(themed, FrameLayout(themed))
                    backgrounds.add((row.background as ColorDrawable).color)
                    root.addView(row, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = 12 })
                }
                check(backgrounds[0] != backgrounds[1]) { "Server backgrounds must differ" }
                val density = themed.resources.displayMetrics.density
                val width = (340 * density).toInt()
                root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                root.layout(0, 0, width, root.measuredHeight)
                val first = root.getChildAt(0)
                val mark = first.findViewById<View>(R.id.job_cluster_mark)
                check(mark.width > 0 && mark.height >= first.height) { "Cluster color mark not visible" }
                for (id in listOf(R.id.job_server, R.id.job_name, R.id.job_node, R.id.cpu_label, R.id.mem_label)) {
                    val text = first.findViewById<TextView>(id)
                    check(text.height >= text.lineHeight) { "Desktop row text clipped: $id" }
                }
                val cpu = first.findViewById<View>(R.id.cpu_ring)
                val mem = first.findViewById<View>(R.id.mem_ring)
                check(cpu.top == mem.top) { "Metrics should share a compact row" }
                val bitmap = Bitmap.createBitmap(width, root.height, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                canvas.drawColor(if (dark) Color.parseColor("#0A121D") else Color.WHITE)
                root.draw(canvas)
                File(targetContext.getExternalFilesDir(null), "desktop-tinted-${if (dark) "dark" else "light"}.png")
                    .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
                factory.onDestroy()
            } catch (error: Throwable) { failure = error }
        }
        prefs.edit().clear().commit()
        failure?.let { throw it }
    }

    private fun render(context: Context, snapshot: JSONObject, dark: Boolean, scale: Float) {
        XiaomiWidgetStore.publish(context, snapshot.toString(), false)
        val compact = XiaomiWidgetStore.read(context)
        var failure: Throwable? = null
        runOnMainSync {
          try {
            val config = Configuration(context.resources.configuration).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                fontScale = scale
            }
            val themed = context.createConfigurationContext(config)
            val root = XiaomiSlurmWidgetProvider.views(themed, 123, compact)
                .apply(themed, FrameLayout(themed))
            check(root.findViewById<TextView>(R.id.xiaomi_counts).text.toString() == "运行 2 · 排队 1")
            check(root.findViewById<TextView>(R.id.xiaomi_job).text.toString() == "MOF_adsorption #42")
            val expected = themed.getColor(R.color.xiaomi_widget_text)
            check(root.findViewById<TextView>(R.id.xiaomi_job).currentTextColor == expected)
            val density = themed.resources.displayMetrics.density
            val width = (360 * density).toInt()
            val height = ((if (scale > 1f) 150 else 110) * density).toInt()
            root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, width, height)
            val footer = root.findViewById<TextView>(R.id.xiaomi_time)
            check(footer.bottom <= height && footer.top >= 0) { "Card footer clipped" }
            for (id in listOf(R.id.xiaomi_counts, R.id.xiaomi_job, R.id.xiaomi_metrics, R.id.xiaomi_time)) {
                val text = root.findViewById<TextView>(id)
                check(text.height >= text.lineHeight) { "Card text row clipped: $id" }
            }
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            root.draw(Canvas(bitmap))
            val file = File(targetContext.getExternalFilesDir(null), "xiaomi-card-${if (dark) "dark" else "light"}.png")
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
          } catch (error: Throwable) { failure = error }
        }
        failure?.let { throw it }
    }
}
