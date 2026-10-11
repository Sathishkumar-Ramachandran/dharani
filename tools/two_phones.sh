#!/usr/bin/env bash
# One command for the two-phone setup:
#   1. builds the APK,
#   2. installs it on every USB-connected Android phone (and grants runtime permissions),
#   3. starts the Dharani server and prints the address to type into both phones.
#
# usage: tools/two_phones.sh [--skip-build] [--port 8080]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=8080; BUILD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) BUILD=0 ;;
    --port) PORT="$2"; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="$HOME/development/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"
PKG=com.dharani.dharani_mobile
APK="$ROOT/mobile-ui/build/app/outputs/flutter-apk/app-debug.apk"

if [[ $BUILD == 1 ]]; then
  (cd "$ROOT/mobile-ui" && flutter build apk --debug)
fi

DEVICES=()
while IFS= read -r line; do [[ -n "$line" ]] && DEVICES+=("$line"); done < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
if [[ ${#DEVICES[@]} -eq 0 ]]; then
  echo "No authorised phone found. Plug it in, enable USB debugging and accept the prompt." >&2
else
  for d in "${DEVICES[@]}"; do
    echo "== $d ($(adb -s "$d" shell getprop ro.product.model | tr -d '\r'))"
    adb -s "$d" install -r "$APK" | tail -1
    for p in ACCESS_FINE_LOCATION RECORD_AUDIO POST_NOTIFICATIONS; do
      adb -s "$d" shell pm grant $PKG android.permission.$p 2>/dev/null || true
    done
    adb -s "$d" shell am start -n $PKG/.MainActivity >/dev/null
    # stop the screen turning off while plugged in (a sleeping phone drops the socket)
    adb -s "$d" shell svc power stayon usb || true
  done
fi

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<your-LAN-IP>')"
echo
echo "Server address for BOTH phones:  http://$IP:$PORT"
echo "Phone A: choose 'I need a ride'.  Phone B: choose 'I drive' (pick vehicle type + plate)."
echo "Both phones must be on the same Wi-Fi as this computer. Press Ctrl-C to stop the server."
echo
cd "$ROOT/server"
dart pub get >/dev/null
exec dart run bin/server.dart --port "$PORT" --journal "$ROOT/server/rides.jsonl"
