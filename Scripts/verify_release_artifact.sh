#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <dmg_path> <version> <with-core|no-core>" >&2
  exit 1
fi

DMG_PATH="$1"
EXPECTED_VERSION="$2"
CORE_MODE="$3"
EXPECTED_ARCH="arm64"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [[ "$CORE_MODE" != "with-core" && "$CORE_MODE" != "no-core" ]]; then
  echo "Unsupported core mode: $CORE_MODE" >&2
  exit 1
fi

checksum_path="${DMG_PATH}.sha256"
if [[ ! -f "$checksum_path" ]]; then
  echo "Checksum not found: $checksum_path" >&2
  exit 1
fi

echo "Verifying disk image: $DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null

expected_checksum="$(awk 'NF { print $1; exit }' "$checksum_path")"
actual_checksum="$(shasum -a 256 "$DMG_PATH" | awk '{ print $1 }')"
if [[ -z "$expected_checksum" || "$expected_checksum" != "$actual_checksum" ]]; then
  echo "SHA256 mismatch for $DMG_PATH" >&2
  echo "Expected: $expected_checksum" >&2
  echo "Actual:   $actual_checksum" >&2
  exit 1
fi

mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/clashbar-release.XXXXXX")"
mounted=0
cleanup() {
  if [[ "$mounted" == "1" ]]; then
    hdiutil detach "$mountpoint" -quiet || true
  fi
  rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$mountpoint" >/dev/null
mounted=1

app_path="$mountpoint/ClashBar.app"
if [[ ! -d "$app_path" ]]; then
  echo "ClashBar.app not found in $DMG_PATH" >&2
  exit 1
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$app_path/Contents/Info.plist"
}

actual_short_version="$(plist_value CFBundleShortVersionString)"
actual_build_number="$(plist_value CFBundleVersion)"
if [[ "$actual_short_version" != "$EXPECTED_VERSION" ]]; then
  echo "Unexpected CFBundleShortVersionString: $actual_short_version" >&2
  exit 1
fi
if [[ -z "$actual_build_number" ]]; then
  echo "CFBundleVersion is empty" >&2
  exit 1
fi

assert_arm64() {
  local label="$1"
  local path="$2"
  local archs
  archs="$(lipo -archs "$path" | tr -d '\r\n')"
  if [[ "$archs" != "$EXPECTED_ARCH" ]]; then
    echo "$label must contain only $EXPECTED_ARCH, found: $archs" >&2
    exit 1
  fi
}

assert_arm64 "ClashBar executable" "$app_path/Contents/MacOS/ClashBar"
assert_arm64 "Proxy Helper executable" "$app_path/Contents/Library/HelperTools/com.clashbar.helper"

if ! codesign --verify --deep --strict "$app_path"; then
  echo "Code signature verification failed: $app_path" >&2
  exit 1
fi

core_path="$(find "$app_path" -type f \( -name mihomo -o -name mihomo.gz \) -print -quit)"
if [[ "$CORE_MODE" == "with-core" ]]; then
  if [[ -z "$core_path" ]]; then
    echo "Expected bundled mihomo core was not found" >&2
    exit 1
  fi
  if [[ "$core_path" == *.gz ]]; then
    core_temp="$(mktemp "${TMPDIR:-/tmp}/clashbar-mihomo.XXXXXX")"
    gunzip -c "$core_path" > "$core_temp"
    assert_arm64 "Bundled mihomo executable" "$core_temp"
    rm -f "$core_temp"
  else
    assert_arm64 "Bundled mihomo executable" "$core_path"
  fi
else
  if [[ -n "$core_path" ]]; then
    echo "Unexpected bundled mihomo core found: $core_path" >&2
    exit 1
  fi
fi

echo "Verified: version=$actual_short_version build=$actual_build_number arch=$EXPECTED_ARCH core=$CORE_MODE"
