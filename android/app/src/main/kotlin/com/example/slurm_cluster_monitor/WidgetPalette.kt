package com.example.slurm_cluster_monitor

import android.content.SharedPreferences
import android.graphics.Color
import org.json.JSONArray
import org.json.JSONObject

data class WidgetPalette(val background: Int, val primary: Int, val secondary: Int, val text: Int, val muted: Int, val track: Int, val baseColor: Int) {
    fun serverBackground(accent: Int): Int = tintedBackground(baseColor, accent, Color.red(text) < 80)
    fun serverForeground(accent: Int): Int = if (Color.red(text) < 80) {
        Color.rgb((Color.red(accent) * .8f).toInt(), (Color.green(accent) * .8f).toInt(),
            (Color.blue(accent) * .8f).toInt())
    } else accent
    companion object {
        fun tintedBackground(base: Int, accent: Int, light: Boolean): Int {
            val alpha = if (light) .18f else .24f
            fun blend(a: Int, b: Int) = (a * alpha + b * (1 - alpha)).toInt()
            return Color.rgb(blend(Color.red(accent), Color.red(base)),
                blend(Color.green(accent), Color.green(base)),
                blend(Color.blue(accent), Color.blue(base)))
        }
        private val serverColors = intArrayOf(
            0xFF6289C6.toInt(), 0xFF5C9E87.toInt(), 0xFFAC81B9.toInt(), 0xFFC19B55.toInt(),
            0xFFC47F88.toInt(), 0xFF659DAA.toInt(), 0xFF8C98BD.toInt(), 0xFF9B9B67.toInt())
        fun serverKey(job: JSONObject): String = job.optString("serverId").ifEmpty {
            job.optString("key").substringBeforeLast('/').ifEmpty { job.optString("serverName") }
        }
        fun identityColor(key: String): Int {
            var hash = 0
            for (char in key) hash = (hash * 31 + char.code) and 0x7fffffff
            return serverColors[hash % serverColors.size]
        }
        /** Also repairs old snapshots that lack colors or have colliding hashes. */
        fun resolveServerColors(jobs: JSONArray): Map<String, Int> {
            val preferred = sortedMapOf<String, Int>()
            for (index in 0 until jobs.length()) {
                val job = jobs.optJSONObject(index) ?: continue
                val key = serverKey(job)
                val cached = job.optLong("serverColor").toInt()
                val color = if (Color.alpha(cached) == 255) cached else identityColor(key)
                preferred.putIfAbsent(key, color)
            }
            val used = mutableSetOf<Int>()
            return preferred.mapValues { (key, preferredColor) ->
                var color = preferredColor
                if (color in used) {
                    val start = serverColors.indexOf(identityColor(key)).coerceAtLeast(0)
                    color = (0 until serverColors.size).map { serverColors[(start + it) % serverColors.size] }
                        .firstOrNull { it !in used } ?: preferredColor
                }
                while (color in used) color = 0xff000000.toInt() or ((color + 0x000b17) and 0x00ffffff)
                used.add(color)
                color
            }
        }
        fun read(data: SharedPreferences): WidgetPalette {
            fun c(value: String) = Color.parseColor(value)
            return when (data.getString("slurm_widget_skin", "ocean")) {
                "daylight" -> WidgetPalette(R.drawable.widget_background_white, c("#087E74"), c("#245FA5"), c("#162533"), c("#536476"), c("#DDE5ED"), c("#FFFFFF"))
                "violet" -> WidgetPalette(R.drawable.widget_background_violet, c("#CAA5FF"), c("#96B4FF"), c("#F3EEFA"), c("#BAACC9"), c("#3A2C50"), c("#20192F"))
                else -> WidgetPalette(R.drawable.widget_background, c("#63DFC5"), c("#79AEFF"), c("#FFFFFF"), c("#9AAEC5"), c("#283443"), c("#131E2C"))
            }
        }
    }
}
