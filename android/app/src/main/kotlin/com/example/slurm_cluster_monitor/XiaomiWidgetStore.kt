package com.example.slurm_cluster_monitor

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

/** A small, credential-free snapshot shared with the :widgetProvider process.
 * SharedPreferences caches are process-local, so the Xiaomi renderer reads an
 * atomic file under a cross-process lock instead of sharing cached preferences.
 */
object XiaomiWidgetStore {
    private const val FILE_NAME = "xiaomi_widget_snapshot.json"

    @Synchronized
    private fun <T> locked(context: Context, action: (AtomicFile) -> T): T {
        RandomAccessFile(File(context.filesDir, "$FILE_NAME.lock"), "rw").use { file ->
            file.channel.use { channel ->
                channel.lock().use {
                    return action(AtomicFile(File(context.filesDir, FILE_NAME)))
                }
            }
        }
    }

    fun publish(context: Context, raw: String?, refreshing: Boolean) {
        val source = runCatching { JSONObject(raw ?: "{}") }.getOrDefault(JSONObject())
        val result = JSONObject().put("version", 1).put("refreshing", refreshing)
        for (key in listOf("nodeSummary", "status", "timestamp")) {
            if (source.has(key)) result.put(key, source.optString(key).take(256))
        }
        for (key in listOf("runningCount", "pendingCount", "offline", "timestampEpochMs")) {
            if (source.has(key) && !source.isNull(key)) result.put(key, source.optLong(key))
        }
        val jobs = source.optJSONArray("running_jobs_json")
        if (!result.has("runningCount") && jobs != null) result.put("runningCount", jobs.length())
        jobs?.optJSONObject(0)?.let { job ->
            val colors = WidgetPalette.resolveServerColors(jobs)
            val first = JSONObject()
            for (key in listOf("serverName", "jobId", "jobName", "nodeList", "cpuPercentText", "memPercentText")) {
                first.put(key, job.optString(key).take(256))
            }
            first.put("stale", job.optBoolean("stale"))
            val color = colors[WidgetPalette.serverKey(job)]
                ?: WidgetPalette.identityColor(WidgetPalette.serverKey(job))
            first.put("serverColor", color.toLong() and 0xffffffffL)
            result.put("firstJob", first)
        }
        val bytes = result.toString().toByteArray(Charsets.UTF_8)
        locked(context) { file ->
            val stream = file.startWrite()
            try {
                stream.write(bytes)
                file.finishWrite(stream)
            } catch (error: Exception) {
                file.failWrite(stream)
                throw error
            }
        }
    }

    fun read(context: Context): JSONObject = runCatching {
        locked(context) { file ->
            require(file.baseFile.length() <= 64 * 1024)
            JSONObject(file.readFully().toString(Charsets.UTF_8))
        }
    }.getOrDefault(JSONObject())
}
