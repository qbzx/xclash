#!/usr/bin/env bash
set -euo pipefail

# Build a runnable macOS x86_64 (Intel) ZenClash.app WITHOUT bundling Mihomo.
#
# Mihomo is deliberately left independent. The running app discovers it via:
#   - the "运行内核 → 选择文件" custom-core setting (stored in preferences),
#   - <repo>/bin/mihomo, or
#   - an executable named `mihomo` on PATH.
# Or run Mihomo yourself and connect with ZENCLASH_CONTROLLER / ZENCLASH_SECRET.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${ZENCLASH_VERSION:-$(sed -n 's/^version = "\([^"]*\)"/\1/p' "${PROJECT_ROOT}/Cargo.toml" | head -n 1)}"
OUTPUT_DIR="${ZENCLASH_OUTPUT_DIR:-${PROJECT_ROOT}/dist}"
APP_DIR="${OUTPUT_DIR}/ZenClash.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
RUST_VERSION="1.99.0"

# 1. This build targets Intel only (no universal binary, no arm64 cross-build).
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "This script builds for Intel Macs (x86_64). Run it on an Intel Mac." >&2
  exit 1
fi

# 2. Pin the toolchain the project's CI uses; the default stable may be too old.
if ! rustup toolchain list 2>/dev/null | grep -q "^${RUST_VERSION}-"; then
  rustup toolchain install "${RUST_VERSION}" --profile minimal --component rustfmt --component clippy
fi
rustup override set "${RUST_VERSION}"

# 3. Build the UI in release mode (native x86_64 on this host).
cd "${PROJECT_ROOT}"
cargo build --release --locked -p zenclash-ui --bin zenclash

# 4. Assemble a minimal app bundle: icon, plist, default profile, recovery,
#    and license. No Mihomo, no GeoData, no service helpers.
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${PROJECT_ROOT}/target/release/zenclash" "${MACOS_DIR}/zenclash"
cp "${PROJECT_ROOT}/platforms/macos/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${PROJECT_ROOT}/platforms/common/default.yaml" "${RESOURCES_DIR}/profile.yaml"
cp "${PROJECT_ROOT}/platforms/common/recovery.yaml" "${RESOURCES_DIR}/recovery.yaml"
cp "${PROJECT_ROOT}/platforms/macos/ZenClash.icns" "${RESOURCES_DIR}/ZenClash.icns"
cp "${PROJECT_ROOT}/LICENSE" "${RESOURCES_DIR}/LICENSE.txt"
chmod 755 "${MACOS_DIR}/zenclash"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION%%-*}" "${CONTENTS_DIR}/Info.plist"

# 5. Ad-hoc sign so Gatekeeper does not block the local build.
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "${APPLE_SIGNING_IDENTITY}" "${APP_DIR}"
else
  codesign --force --deep --sign - "${APP_DIR}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "Built ${APP_DIR} (x86_64, no bundled Mihomo)"
