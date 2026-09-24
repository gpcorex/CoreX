package org.central.media

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

object ApiClient {
    private const val BASE = "https://cen-tral.duckdns.org/media-api"

    fun health(): JSONObject = get("/health")
    fun items(limit: Int = 50): JSONObject = get("/video/items?limit=" + limit)
    fun liveChannels(): JSONObject = get("/live/channels")

    private fun get(path: String): JSONObject {
        val conn = URL(BASE + path).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "GET"
            conn.connectTimeout = 8000
            conn.readTimeout = 12000
            conn.setRequestProperty("Accept", "application/json")
            val code = conn.responseCode
            val body = (if (code in 200..299) conn.inputStream else conn.errorStream)
                .bufferedReader()
                .use { it.readText() }

            if (code !in 200..299) {
                throw IllegalStateException("HTTP " + code + ": " + body)
            }
            return JSONObject(body)
        } finally {
            conn.disconnect()
        }
    }
}
