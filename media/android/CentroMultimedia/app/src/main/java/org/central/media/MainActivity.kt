package org.central.media

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private lateinit var root: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
            setBackgroundColor(Color.rgb(16, 17, 20))
        }

        val scroll = ScrollView(this).apply {
            addView(root, ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ))
        }

        setContentView(scroll)
        title("Centro Multimedia")
        subtitle("Películas · Series · Anime · TV en vivo")

        val progress = ProgressBar(this)
        root.addView(progress)

        thread {
            try {
                val health = ApiClient.health()
                val items = ApiClient.items(20).optJSONArray("items")
                val live = ApiClient.liveChannels().optJSONArray("channels")

                runOnUiThread {
                    root.removeView(progress)

                    section("Estado")
                    line("API conectada")
                    line("Videos: " + health.optInt("video_items"))
                    line("Canales: " + health.optInt("live_channels"))

                    section("Catálogo")
                    if (items == null || items.length() == 0) {
                        muted("Todavía no hay títulos cargados.")
                    } else {
                        for (i in 0 until items.length()) {
                            val item = items.getJSONObject(i)
                            card(item.optString("title", "Sin título"), item.optString("kind", ""))
                        }
                    }

                    section("TV en vivo")
                    if (live == null || live.length() == 0) {
                        muted("Todavía no hay canales cargados.")
                    } else {
                        for (i in 0 until live.length()) {
                            val item = live.getJSONObject(i)
                            card(item.optString("name", "Canal"), item.optString("quality", ""))
                        }
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    root.removeView(progress)
                    section("Conexión")
                    error("No se pudo conectar con la API")
                    muted(e.message ?: e.javaClass.simpleName)
                }
            }
        }
    }

    private fun title(text: String) {
        root.addView(TextView(this).apply {
            this.text = text
            textSize = 28f
            setTextColor(Color.WHITE)
            gravity = Gravity.START
        })
    }

    private fun subtitle(text: String) {
        root.addView(TextView(this).apply {
            this.text = text
            textSize = 14f
            setTextColor(Color.LTGRAY)
            setPadding(0, 8, 0, 24)
        })
    }

    private fun section(text: String) {
        root.addView(TextView(this).apply {
            this.text = text
            textSize = 20f
            setTextColor(Color.WHITE)
            setPadding(0, 24, 0, 10)
        })
    }

    private fun line(text: String) {
        root.addView(TextView(this).apply {
            this.text = text
            textSize = 16f
            setTextColor(Color.WHITE)
            setPadding(0, 4, 0, 4)
        })
    }

    private fun muted(text: String) {
        root.addView(TextView(this).apply {
            this.text = text
            textSize = 15f
            setTextColor(Color.GRAY)
            setPadding(0, 6, 0, 10)
        })
    }

    private fun error(text: String) {
        root.addView(TextView(this).apply {
            this.text = text
            textSize = 17f
            setTextColor(Color.rgb(255, 140, 140))
            setPadding(0, 6, 0, 10)
        })
    }

    private fun card(title: String, meta: String) {
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 18, 20, 18)
            setBackgroundColor(Color.rgb(31, 33, 38))

            addView(TextView(this@MainActivity).apply {
                text = title
                textSize = 17f
                setTextColor(Color.WHITE)
            })
            if (meta.isNotBlank()) {
                addView(TextView(this@MainActivity).apply {
                    text = meta
                    textSize = 13f
                    setTextColor(Color.LTGRAY)
                    setPadding(0, 5, 0, 0)
                })
            }
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            setMargins(0, 0, 0, 12)
        })
    }
}
