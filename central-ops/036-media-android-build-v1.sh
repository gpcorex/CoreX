#!/usr/bin/env bash
set -euo pipefail

APP="/home/ubuntu/Central/media_center/android/CentroMultimedia"
OUT="/var/lib/conector/media-android-build-v1.txt"
RELEASES="/home/ubuntu/Central/media_center/android/releases"
APK_SRC="$APP/app/build/outputs/apk/debug/app-debug.apk"
APK_DST="$RELEASES/CentroMultimedia-v0.1.0-debug.apk"

mkdir -p "$RELEASES" /var/lib/conector
chown -R ubuntu:ubuntu "$APP" "$RELEASES"

BUILD_LOG="/tmp/media-android-build-v1.log"
rm -f "$BUILD_LOG" "$APK_DST"

sudo -u ubuntu env ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk   "$APP/gradlew" -p "$APP" :app:assembleDebug --stacktrace --no-daemon   >"$BUILD_LOG" 2>&1

test -f "$APK_SRC"
cp "$APK_SRC" "$APK_DST"
chown ubuntu:ubuntu "$APK_DST"

SIZE="$(stat -c %s "$APK_DST")"
SHA256="$(sha256sum "$APK_DST" | awk '{print $1}')"

{
  echo "MEDIA_ANDROID_BUILD_V1_READY"
  echo "apk=$APK_DST"
  echo "size_bytes=$SIZE"
  echo "sha256=$SHA256"
  echo "build_status=success"
  echo "build_log=$BUILD_LOG"
  echo "last_build_lines:"
  tail -n 40 "$BUILD_LOG"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-android-build-v1.txt" || true
fi

echo "MEDIA_ANDROID_BUILD_V1_READY"
