#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ROOT/Scripts"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

APP_VERSION="$1"
BUILD_NUMBER="${BUILD_NUMBER:-$APP_VERSION}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
MIHOMO_VERSION="${MIHOMO_VERSION:-}"

if [[ "$TARGET_ARCH" != "arm64" ]]; then
  echo "Release packaging only supports TARGET_ARCH=arm64" >&2
  exit 1
fi

build_variant() {
  local core_mode="$1"
  local dmg_suffix="$2"
  local prepare_core="$3"

  APP_VERSION="$APP_VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  TARGET_ARCH="$TARGET_ARCH" \
  MIHOMO_VERSION="$MIHOMO_VERSION" \
  PREPARE_MIHOMO_BINARY="$prepare_core" \
  BUNDLE_MIHOMO_BINARY="$prepare_core" \
  REQUIRE_MIHOMO_BINARY="$prepare_core" \
  DMG_SUFFIX="$dmg_suffix" \
  "$SCRIPTS_DIR/build.sh" all

  "$SCRIPTS_DIR/verify_release_artifact.sh" \
    "$ROOT/dist/ClashBar-${APP_VERSION}-${dmg_suffix}.dmg" \
    "$APP_VERSION" \
    "$core_mode"
}

build_variant with-core apple-silicon 1
build_variant no-core apple-silicon-no-core 0

echo "Release artifacts are ready under $ROOT/dist"
