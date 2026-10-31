package com.example.slurm_cluster_monitor

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var keyResult: MethodChannel.Result? = null
    private var widgetSetup: XiaomiWidgetSetup? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        widgetSetup?.close()
        widgetSetup = XiaomiWidgetSetup(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "slurm_monitor/widgets")
            .setMethodCallHandler { call, result -> widgetSetup!!.onCall(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "slurm_monitor/files").setMethodCallHandler { call, result ->
            if (call.method != "pickPrivateKey") { result.notImplemented(); return@setMethodCallHandler }
            if (keyResult != null) { result.error("BUSY", "文件选择器已打开", null); return@setMethodCallHandler }
            keyResult = result
            try {
                @Suppress("DEPRECATION")
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    type = "*/*"
                    addCategory(Intent.CATEGORY_OPENABLE)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }, 7314)
            } catch (_: Exception) {
                keyResult = null
                result.error("PICKER", "无法打开系统文件选择器", null)
            }
        }
    }
    override fun onDestroy() {
        widgetSetup?.close()
        super.onDestroy()
    }
    @Deprecated("Used by FlutterActivity's document picker callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7314) return
        val result = keyResult ?: return
        keyResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        try {
            val bytes = contentResolver.openInputStream(uri)?.use { stream ->
                val output = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(4096)
                while (true) {
                    val count = stream.read(chunk)
                    if (count < 0) break
                    if (output.size() + count > 512 * 1024) throw IllegalArgumentException("size")
                    output.write(chunk, 0, count)
                }
                output.toByteArray()
            } ?: throw IllegalArgumentException("file")
            var name = "私钥文件"
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) name = it.getString(0) ?: name
            }
            result.success(mapOf("name" to name, "content" to bytes.toString(Charsets.UTF_8)))
        } catch (_: Exception) {
            result.error("KEY_FILE", "无法读取私钥文件，文件大小需小于 512 KB", null)
        }
    }
}
