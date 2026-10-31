package com.example.slurm_cluster_monitor

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class XiaomiWidgetSetup(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val uri = Uri.parse("content://com.miui.personalassistant.widget.external")

    private fun supported(method: String): Boolean = runCatching {
        activity.contentResolver.call(uri, method, null, null)?.getBoolean(method) == true
    }.getOrDefault(false)

    fun onCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getCapabilities" && call.method != "requestXiaomiWidget") {
            result.notImplemented()
            return
        }
        // Xiaomi documents these ContentProvider queries as worker-thread calls.
        worker.execute {
            val manager = AppWidgetManager.getInstance(activity)
            val component = ComponentName(activity, XiaomiSlurmWidgetProvider::class.java)
            val widget = Build.VERSION.SDK_INT >= 26 && supported("isMiuiWidgetSupported")
            val detail = widget && supported("isMiuiWidgetDetailPageSupported")
            val pin = Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported
            val count = manager.getAppWidgetIds(component).size
            main.post {
                if (activity.isDestroyed || activity.isFinishing) {
                    result.error("ACTIVITY_CLOSED", "请重新打开小米负一屏设置", null)
                } else if (call.method == "getCapabilities") {
                    result.success(mapOf(
                        "widgetSupported" to widget,
                        "detailSupported" to detail,
                        "pinSupported" to pin,
                        "installedCount" to count,
                    ))
                } else {
                    val accepted = widget && detail && pin && runCatching {
                        val extras = Bundle().apply {
                            putString("addType", "appWidgetDetail")
                            putString("widgetName", component.flattenToString())
                        }
                        manager.requestPinAppWidget(component, extras, null)
                    }.getOrDefault(false)
                    // A true result means the system accepted the request, not
                    // that the user added a widget or that Xiaomi approved it.
                    result.success(accepted)
                }
            }
        }
    }

    fun close() { worker.shutdown() }
}
