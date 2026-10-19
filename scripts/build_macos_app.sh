#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${ZENCLASH_VERSION:-$(sed -n 's/^version = "\([^"]*\)"/\1/p' "${PROJECT_ROOT}/Cargo.toml" | head -n 1)}"
OUTPUT_DIR="${ZENCLASH_OUTPUT_DIR:-${PROJECT_ROOT}/target}"
ARCH="${ZENCLASH_ARCH:-arm64}"
case "${ARCH}" in
  arm64) TARGET_TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TARGET_TRIPLE="x86_64-apple-darwin" ;;
  *) echo "Unsupported macOS architecture: ${ARCH}" >&2; exit 2 ;;
esac
APP_DIR="${OUTPUT_DIR}/ZenClash.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PROFILE_PATH="${ZENCLASH_CONFIG:-${PROJECT_ROOT}/platforms/common/default.yaml}"
CARGO_OUTPUT_ROOT="${CARGO_TARGET_DIR:-${PROJECT_ROOT}/target}"

HOST_ARCH="$(uname -m)"
if [[ "${ARCH}" == "arm64" && "${HOST_ARCH}" != "arm64" ]]; then
  echo "Building arm64 requires an Apple Silicon host; use ZENCLASH_ARCH=x86_64 to cross-compile Intel." >&2
  exit 1
fi

if [[ ! -f "${PROFILE_PATH}" ]]; then
  echo "Mihomo profile not found: ${PROFILE_PATH}" >&2
  exit 1
fi

cd "${PROJECT_ROOT}"
rustup target add "${TARGET_TRIPLE}"
ZENCLASH_VERSION="${VERSION}" \
cargo build --release --locked -p zenclash-ui --bin zenclash --target "${TARGET_TRIPLE}"
ZENCLASH_VERSION="${VERSION}" \
cargo build --release --locked -p zenclash-service --features standalone,client --bin zenclash-service --bin zenclash-service-install --bin zenclash-service-uninstall --target "${TARGET_TRIPLE}"

GUI_PATH="${CARGO_OUTPUT_ROOT}/${TARGET_TRIPLE}/release/zenclash"
SERVICE_PATH="${CARGO_OUTPUT_ROOT}/${TARGET_TRIPLE}/release/zenclash-service"
for binary in "${GUI_PATH}" "${SERVICE_PATH}"; do
  if [[ ! -f "${binary}" || ! -s "${binary}" || ! -x "${binary}" ]]; then
    echo "The build did not produce an executable: ${binary}" >&2
    exit 1
  fi
done
if [[ "${TARGET_TRIPLE}" == "x86_64-apple-darwin" ]]; then
  # Cross-compiled for Intel on an Apple Silicon host: the binaries cannot run
  # here, so verify their architecture instead. `-b` omits the path so the
  # `x86_64-apple-darwin` in it cannot satisfy the grep.
  for binary in "${GUI_PATH}" "${SERVICE_PATH}"; do
    if ! file -b "${binary}" | grep -Eq 'x86_64'; then
      echo "The cross-compiled binary is not Intel: ${binary}" >&2
      exit 1
    fi
  done
elif ! service_version="$("${SERVICE_PATH}" --version)" || [[ -z "${service_version//[[:space:]]/}" ]]; then
  echo "The service executable failed its version check." >&2
  exit 1
fi

for tool in zenclash-service-install zenclash-service-uninstall; do
  tool_path="${CARGO_OUTPUT_ROOT}/${TARGET_TRIPLE}/release/${tool}"
  if [[ ! -s "${tool_path}" || ! -x "${tool_path}" ]]; then
    echo "Native service maintenance tool is missing or not executable: ${tool_path}" >&2
    exit 1
  fi
done

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${GUI_PATH}" "${MACOS_DIR}/zenclash"
cp "${SERVICE_PATH}" "${MACOS_DIR}/zenclash-service"
for tool in zenclash-service-install zenclash-service-uninstall; do
  cp "${CARGO_OUTPUT_ROOT}/${TARGET_TRIPLE}/release/${tool}" "${MACOS_DIR}/${tool}"
  chmod 755 "${MACOS_DIR}/${tool}"
done
cp "${PROJECT_ROOT}/platforms/macos/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${PROFILE_PATH}" "${RESOURCES_DIR}/profile.yaml"
cp "${PROJECT_ROOT}/platforms/common/recovery.yaml" "${RESOURCES_DIR}/recovery.yaml"
cp "${PROJECT_ROOT}/LICENSE" "${RESOURCES_DIR}/LICENSE.txt"
chmod 755 "${MACOS_DIR}/zenclash" "${MACOS_DIR}/zenclash-service"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION%%-*}" "${CONTENTS_DIR}/Info.plist"

if [[ -f "${PROJECT_ROOT}/platforms/macos/ZenClash.icns" ]]; then
  cp "${PROJECT_ROOT}/platforms/macos/ZenClash.icns" "${RESOURCES_DIR}/ZenClash.icns"
elif [[ -f "${PROJECT_ROOT}/examples/clash-party/build/icon.icns" ]]; then
  cp "${PROJECT_ROOT}/examples/clash-party/build/icon.icns" "${RESOURCES_DIR}/ZenClash.icns"
fi

for executable in "${MACOS_DIR}/zenclash-service" "${MACOS_DIR}/zenclash-service-install" "${MACOS_DIR}/zenclash-service-uninstall"; do
  if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "${APPLE_SIGNING_IDENTITY}" "${executable}"
  else
    codesign --force --sign - "${executable}"
  fi
  codesign --verify --strict --verbose=2 "${executable}"
done
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "${APPLE_SIGNING_IDENTITY}" "${APP_DIR}"
else
  codesign --force --deep --sign - "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
echo "Built ${APP_DIR} (${TARGET_TRIPLE}, no bundled Mihomo)"
