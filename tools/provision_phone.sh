#!/usr/bin/env bash
# Configures an installed Dharani app over USB without touching the screen (fleet setup).
#   tools/provision_phone.sh <adb-serial> rider  "<name>" <lang> <[server-url|auto]>
#   tools/provision_phone.sh <adb-serial> driver "<name>" <lang> <[server-url|auto]> <auto|cab|bike> <plate> [model]
set -euo pipefail
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
PKG=com.dharani.dharani_mobile
serial=$1; role=$2; name=$3; lang=$4; server=${5:-auto}
tmp="$(mktemp)"
if [[ $role == driver ]]; then
  printf '{"role":"driver","name":"%s","lang":"%s","vehicle":{"type":"%s","plate":"%s","model":"%s"},"server":"%s"}' "$name" "$lang" "$6" "$7" "${8:-}" "$server" > "$tmp"
else
  printf '{"role":"rider","name":"%s","lang":"%s","server":"%s"}' "$name" "$lang" "$server" > "$tmp"
fi
adb -s "$serial" push "$tmp" /data/local/tmp/provision.json >/dev/null
adb -s "$serial" shell "chmod 644 /data/local/tmp/provision.json; am force-stop $PKG; run-as $PKG sh -c 'mkdir -p files && cp /data/local/tmp/provision.json files/provision.json'"
adb -s "$serial" shell am start -n "$PKG/.MainActivity" >/dev/null
rm -f "$tmp"
echo "provisioned $serial as $role ($name, $lang)"
