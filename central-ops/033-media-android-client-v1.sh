#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/android"
APP="$BASE/CentroMultimedia"
OUT="/var/lib/conector/media-android-client-v1.txt"
mkdir -p "$APP/app/src/main/java/org/central/media" "$APP/app/src/main/res/values" /var/lib/conector

cat > "$APP/settings.gradle.kts" <<'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "CentroMultimedia"
include(":app")
EOF

cat > "$APP/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
EOF

cat > "$APP/app/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.central.media"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.central.media"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }
}

kotlinOptions {
    jvmTarget = "17"
}
EOF

cat > "$APP/app/src/main/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        android:allowBackup="true"
        android:label="Centro Multimedia"
        android:theme="@style/AppTheme"
        android:usesCleartextTraffic="false">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

cat > "$APP/app/src/main/res/values/styles.xml" <<'EOF'
<resources>
    <style name="AppTheme" parent="android:style/Theme.Material.NoActionBar">
        <item name="android:fontFamily">sans</item>
        <item name="android:navigationBarColor">#101114</item>
        <item name="android:statusBarColor">#101114</item>
        <item name="android:windowLightStatusBar">false</item>
    </style>
</resources>
EOF

cat > "$APP/app/src/main/java/org/central/media/ApiClient.kt" <<'EOF'
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
EOF

cat > "$APP/app/src/main/java/org/central/media/MainActivity.kt" <<'EOF'
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
EOF

JAVA="$(command -v java || true)"
GRADLE="$(command -v gradle || true)"
SDK="$ANDROID_HOME"
if [ -z "$SDK" ]; then
  SDK="$ANDROID_SDK_ROOT"
fi

{
  echo "MEDIA_ANDROID_CLIENT_V1_READY"
  echo "project=$APP"
  echo "api_base=https://cen-tral.duckdns.org/media-api"
  if [ -n "$JAVA" ]; then echo "java=$JAVA"; else echo "java=missing"; fi
  if [ -n "$GRADLE" ]; then echo "gradle=$GRADLE"; else echo "gradle=missing"; fi
  if [ -n "$SDK" ]; then echo "android_sdk=$SDK"; else echo "android_sdk=missing"; fi
  echo "main=$APP/app/src/main/java/org/central/media/MainActivity.kt"
  echo "client=$APP/app/src/main/java/org/central/media/ApiClient.kt"
  echo "manifest=$APP/app/src/main/AndroidManifest.xml"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-android-client-v1.txt" || true
fi

echo "MEDIA_ANDROID_CLIENT_V1_READY"
