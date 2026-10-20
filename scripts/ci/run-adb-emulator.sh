#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/adb-e2e
adb root
adb wait-for-device
adb shell svc wifi enable
adb shell settings put global adb_wifi_enabled 1

# A harmless resource-only APK exercises streamed installation and verification.
tools="$(tr -d '[:space:]' < android/build-tools-version.txt)"
sdk="$(tr -d '[:space:]' < android/compile-sdk-version.txt)"
fixture_dir="$(mktemp -d)"
test_pid=''
cleanup() {
  if [[ -n "$test_pid" ]] && kill -0 "$test_pid" 2>/dev/null; then
    kill "$test_pid" || true
    wait "$test_pid" || true
  fi
  # Do not capture the transient pairing code dialog in uploaded screenshots.
  adb shell input keyevent KEYCODE_HOME || true
  adb exec-out screencap -p > build/adb-e2e/final-screen.png || true
  adb logcat -d -t 1500 > build/adb-e2e/logcat.txt || true
  rm -rf -- "$fixture_dir"
}
trap cleanup EXIT
cat > "$fixture_dir/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="tech.kirikira.kiribox.fixture" android:versionCode="1" android:versionName="1.0">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="35" />
  <application android:label="KiriBox test fixture" android:hasCode="false" />
</manifest>
XML
"$ANDROID_HOME/build-tools/$tools/aapt2" link --manifest "$fixture_dir/AndroidManifest.xml" \
  -I "$ANDROID_HOME/platforms/android-$sdk/android.jar" -o "$fixture_dir/unsigned.apk"
keytool -genkeypair -noprompt -keystore "$fixture_dir/fixture.p12" -storepass android \
  -alias fixture -keyalg RSA -validity 2 -dname 'CN=Disposable integration fixture' >/dev/null 2>&1
"$ANDROID_HOME/build-tools/$tools/apksigner" sign --ks "$fixture_dir/fixture.p12" \
  --ks-key-alias fixture --ks-pass pass:android --out "$fixture_dir/fixture.apk" "$fixture_dir/unsigned.apk"
export KIRIBOX_E2E_FIXTURE="$fixture_dir/fixture.apk"

flutter test --no-pub --timeout 10m --dart-define=KIRIBOX_ADB_E2E=true \
  -d emulator-5554 integration_test/adb_device_test.dart > build/adb-e2e/flutter-test.log 2>&1 &
test_pid=$!
python3 scripts/ci/pair-adb-emulator.py
result=0
wait "$test_pid" || result=$?
test_pid=''
cat build/adb-e2e/flutter-test.log
if [[ "$result" != 0 ]]; then exit "$result"; fi
adb shell run-as tech.kirikira.kiribox.debug cat files/kiribox-adb-passed | tee build/adb-e2e/result.txt
adb exec-out run-as tech.kirikira.kiribox.debug cat files/kiribox-adb-screenshot.png > build/adb-e2e/adb-screenshot.png
