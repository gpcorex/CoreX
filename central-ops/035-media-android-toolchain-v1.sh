#!/usr/bin/env bash
set -euo pipefail

APP="/home/ubuntu/Central/media_center/android/CentroMultimedia"
OUT="/var/lib/conector/media-android-toolchain-v1.txt"
SDK="/opt/android-sdk"
GRADLE_VERSION="8.9"
GRADLE_DIR="/opt/gradle/gradle-$GRADLE_VERSION"

mkdir -p /var/lib/conector /opt/gradle "$SDK/cmdline-tools"

if [ ! -x "$GRADLE_DIR/bin/gradle" ]; then
  TMP="/tmp/gradle-$GRADLE_VERSION-bin.zip"
  curl -fL --retry 3 --connect-timeout 20     "https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip"     -o "$TMP"
  rm -rf "$GRADLE_DIR"
  unzip -q "$TMP" -d /opt/gradle
fi

if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  TMP="/tmp/android-commandlinetools.zip"
  curl -fL --retry 3 --connect-timeout 20     "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"     -o "$TMP"
  rm -rf "$SDK/cmdline-tools/latest" /tmp/android-cmdline-unpack
  mkdir -p /tmp/android-cmdline-unpack
  unzip -q "$TMP" -d /tmp/android-cmdline-unpack
  mkdir -p "$SDK/cmdline-tools/latest"
  cp -a /tmp/android-cmdline-unpack/cmdline-tools/. "$SDK/cmdline-tools/latest/"
fi

yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/tmp/android-licenses.txt || true

"$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK"   "platform-tools"   "platforms;android-35"   "build-tools;35.0.0"

cat > "$APP/local.properties" <<EOF
sdk.dir=$SDK
EOF

cat > "$APP/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx384m -XX:MaxMetaspaceSize=256m -Dfile.encoding=UTF-8
org.gradle.daemon=false
org.gradle.parallel=false
android.useAndroidX=true
EOF

cat > "$APP/gradlew" <<EOF
#!/usr/bin/env bash
exec "$GRADLE_DIR/bin/gradle" "\$@"
EOF
chmod 755 "$APP/gradlew"

chown -R ubuntu:ubuntu "$APP"
chown -R ubuntu:ubuntu "$SDK" /opt/gradle

JAVA_VER="$(java -version 2>&1 | head -1)"
GRADLE_VER="$(sudo -u ubuntu "$APP/gradlew" --version | awk '/Gradle /{print $2; exit}')"
SDKMANAGER_VER="$(sudo -u ubuntu "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --version | head -1)"

{
  echo "MEDIA_ANDROID_TOOLCHAIN_V1_READY"
  echo "java=$JAVA_VER"
  echo "gradle=$GRADLE_VER"
  echo "android_sdk=$SDK"
  echo "sdkmanager=$SDKMANAGER_VER"
  echo "platform_android_35=$(test -d "$SDK/platforms/android-35" && echo yes || echo no)"
  echo "build_tools_35=$(test -d "$SDK/build-tools/35.0.0" && echo yes || echo no)"
  echo "gradlew=$APP/gradlew"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-android-toolchain-v1.txt" || true
fi

echo "MEDIA_ANDROID_TOOLCHAIN_V1_READY"
