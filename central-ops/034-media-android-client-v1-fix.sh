#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/android"
APP="$BASE/CentroMultimedia"
OUT="/var/lib/conector/media-android-client-v1-fix.txt"
mkdir -p "$APP" /var/lib/conector

JAVA="$(command -v java || true)"
GRADLE="$(command -v gradle || true)"
ANDROID_HOME_VALUE="${ANDROID_HOME:-}"
ANDROID_SDK_ROOT_VALUE="${ANDROID_SDK_ROOT:-}"

SDK="$ANDROID_HOME_VALUE"
if [ -z "$SDK" ]; then
  SDK="$ANDROID_SDK_ROOT_VALUE"
fi

{
  echo "MEDIA_ANDROID_CLIENT_V1_FIX_READY"
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
  conector-publish-result "$OUT" "vm-results/media-android-client-v1-fix.txt" || true
fi

echo "MEDIA_ANDROID_CLIENT_V1_FIX_READY"
