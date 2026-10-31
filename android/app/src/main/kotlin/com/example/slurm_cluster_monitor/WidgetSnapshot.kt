package com.example.slurm_cluster_monitor

import android.content.SharedPreferences
import org.json.JSONObject

/** Reject results published by a producer using an older endpoint configuration. */
object WidgetSnapshot {
    fun read(data: SharedPreferences): JSONObject {
        val snapshot = runCatching {
            JSONObject(data.getString("slurm_widget_snapshot", "{}") ?: "{}")
        }.getOrElse { JSONObject() }
        val expected = data.getString("slurm_widget_configuration", null)
        if (expected != null && snapshot.optString("configuration") != expected) {
            return JSONObject().put("status", "连接设置已更新，请刷新").put("nodeSummary", "空闲节点 —")
        }
        return snapshot
    }
}
