#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
test_root="$(mktemp -d)"
[[ "${test_root}" == /* && "${test_root}" != / && -d "${test_root}" && ! -L "${test_root}" ]]
mock_bin="${test_root}/bin"
mock_target="${test_root}/target"
app_dir="${test_root}/output/ZenClash.app"
sign_log="${test_root}/codesign.log"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${mock_bin}"

cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -m ]]
printf '%s\n' "${MOCK_HOST_ARCH:-arm64}"
EOF
cat >"${mock_bin}/file" <<'EOF'
#!/usr/bin/env bash
# The GUI and the service can report different architectures so a test can make
# only one of them wrong; MOCK_GUI_ARCH defaults to the service architecture.
target="${1:?}"
[[ "${target}" == -b ]] && target="${2:?}"
arch="${MOCK_SERVICE_ARCH}"
if [[ "${target##*/}" == zenclash ]]; then
  arch="${MOCK_GUI_ARCH:-${MOCK_SERVICE_ARCH}}"
fi
if [[ "${1:-}" == -b ]]; then
  printf 'Mach-O 64-bit executable %s\n' "${arch}"
else
  printf '%s: Mach-O 64-bit executable %s\n' "${1}" "${arch}"
fi
EOF
cat >"${mock_bin}/rustup" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "target add ${MOCK_TARGET_TRIPLE}" ]]
EOF
cat >"${mock_bin}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output="${CARGO_TARGET_DIR}/${MOCK_TARGET_TRIPLE}/release"
mkdir -p "${output}"
case " $* " in
  *' -p zenclash-service '*)
    [[ " $* " == *' --features standalone,client '* ]]
    [[ " $* " == *' --bin zenclash-service '* ]]
    [[ " $* " == *" --target ${MOCK_TARGET_TRIPLE} "* ]]
    case "${MOCK_SERVICE_FAILURE:-}" in
      missing) exit 0 ;;
      empty) : >"${output}/zenclash-service" ;;
      version) printf '#!/usr/bin/env bash\nexit 1\n' >"${output}/zenclash-service" ;;
      empty_version) printf '#!/usr/bin/env bash\nexit 0\n' >"${output}/zenclash-service" ;;
      whitespace_version) printf '#!/usr/bin/env bash\nprintf " \\t\\n"\n' >"${output}/zenclash-service" ;;
      *) printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]]\nprintf "zenclash-service fixture\\n"\n' >"${output}/zenclash-service" ;;
    esac
    chmod +x "${output}/zenclash-service"
    for tool in zenclash-service-install zenclash-service-uninstall; do
      [[ " $* " == *" --bin ${tool} "* ]]
      cp "${output}/zenclash-service" "${output}/${tool}"
    done
    ;;
  *)
    [[ " $* " == *' -p zenclash-ui '* ]]
    printf '#!/usr/bin/env bash\nexit 0\n' >"${output}/zenclash"
    chmod +x "${output}/zenclash"
    ;;
esac
EOF
cat >"${mock_bin}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_SIGN_LOG}"
# Require actual staged payload even when the bundle itself is the sign target.
if [[ ! -s "${MOCK_APP_DIR}/Contents/MacOS/zenclash-service" || ! -x "${MOCK_APP_DIR}/Contents/MacOS/zenclash-service" ]]; then
  echo 'The staged App is missing an executable service payload' >&2
  exit 1
fi
for tool in zenclash-service-install zenclash-service-uninstall; do
  [[ -s "${MOCK_APP_DIR}/Contents/MacOS/${tool}" && -x "${MOCK_APP_DIR}/Contents/MacOS/${tool}" ]]
done
EOF
chmod +x "${mock_bin}/"*

run_build() {
  # The fixed native plist utility is replaced only in this shell; the production
  # script is sourced unchanged and all copies/sign targets are real test files.
  PATH="${mock_bin}:${PATH}" \
    CARGO_TARGET_DIR="${mock_target}" \
    ZENCLASH_VERSION=9.8.7 \
    ZENCLASH_ARCH="${1}" \
    ZENCLASH_OUTPUT_DIR="${test_root}/output" \
    MOCK_SIGN_LOG="${sign_log}" \
    MOCK_APP_DIR="${app_dir}" \
    MOCK_TARGET_TRIPLE="${2}" \
    MOCK_SERVICE_ARCH="${3}" \
    MOCK_GUI_ARCH="${MOCK_GUI_ARCH:-}" \
    MOCK_HOST_ARCH="${MOCK_HOST_ARCH:-}" \
    APPLE_SIGNING_IDENTITY="${4:-}" \
    MOCK_SERVICE_FAILURE="${5:-}" \
    bash -c 'function /usr/libexec/PlistBuddy { [[ "$1" == -c && -f "$3" ]]; }; source "$1"' \
      macos-payload-test "${project_root}/scripts/build_macos_app.sh"
}

assert_payload_and_order() {
  local triple="${1}"
  cmp "${mock_target}/${triple}/release/zenclash" "${app_dir}/Contents/MacOS/zenclash"
  cmp "${mock_target}/${triple}/release/zenclash-service" \
    "${app_dir}/Contents/MacOS/zenclash-service"
  for tool in zenclash-service-install zenclash-service-uninstall; do
    cmp "${mock_target}/${triple}/release/${tool}" "${app_dir}/Contents/MacOS/${tool}"
    grep -Fq -- "--verify --strict --verbose=2 ${app_dir}/Contents/MacOS/${tool}" "${sign_log}"
  done
  # The bundle must not contain a bundled Mihomo core or GeoData.
  [[ ! -e "${app_dir}/Contents/Resources/mihomo" ]]
  [[ ! -e "${app_dir}/Contents/Resources/geoip.metadb" ]]
  [[ ! -e "${app_dir}/Contents/Resources/geosite.dat" ]]
  local helper_sign helper_verify bundle_sign bundle_verify
  helper_sign="$(grep -n -- '--force.*--sign.*Contents/MacOS/zenclash-service$' "${sign_log}" | cut -d: -f1)"
  helper_verify="$(grep -n -- '--verify.*Contents/MacOS/zenclash-service$' "${sign_log}" | cut -d: -f1)"
  bundle_sign="$(grep -n -- '--force.*--sign.*ZenClash.app$' "${sign_log}" | cut -d: -f1)"
  bundle_verify="$(grep -n -- '--verify.*ZenClash.app$' "${sign_log}" | cut -d: -f1)"
  [[ -n "${helper_sign}" && -n "${helper_verify}" && -n "${bundle_sign}" && -n "${bundle_verify}" ]]
  [[ "${helper_sign}" -lt "${helper_verify}" && "${helper_verify}" -lt "${bundle_sign}" && "${bundle_sign}" -lt "${bundle_verify}" ]]
}

# arm64 (native) — the service runs its --version check.
run_build arm64 aarch64-apple-darwin arm64
assert_payload_and_order aarch64-apple-darwin
grep -Fq -- '--sign - ' "${sign_log}"
: >"${sign_log}"
run_build arm64 aarch64-apple-darwin arm64 'Fixture Developer ID'
assert_payload_and_order aarch64-apple-darwin
grep -Fq -- '--options runtime --timestamp --sign Fixture Developer ID ' "${sign_log}"
: >"${sign_log}"

# x86_64 (cross-compiled) — the service is verified by architecture, not execution.
run_build x86_64 x86_64-apple-darwin x86_64
assert_payload_and_order x86_64-apple-darwin
grep -Fq -- '--sign - ' "${sign_log}"
cp "${app_dir}/Contents/MacOS/zenclash-service" "${test_root}/accepted-helper"
printf 'preserve existing bundle\n' >"${app_dir}/preserved-marker"

for failure in missing empty; do
  rm -f "${mock_target}/aarch64-apple-darwin/release/zenclash-service"
  : >"${sign_log}"
  if run_build arm64 aarch64-apple-darwin arm64 '' "${failure}" >"${test_root}/${failure}.log" 2>&1; then
    printf 'macOS packaging unexpectedly accepted %s service payload\n' "${failure}" >&2
    exit 1
  fi
  [[ ! -s "${sign_log}" ]]
  cmp "${test_root}/accepted-helper" "${app_dir}/Contents/MacOS/zenclash-service"
  [[ "$(cat "${app_dir}/preserved-marker")" == 'preserve existing bundle' ]]
done
for failure in version empty_version whitespace_version; do
  rm -f "${mock_target}/aarch64-apple-darwin/release/zenclash-service"
  : >"${sign_log}"
  if run_build arm64 aarch64-apple-darwin arm64 '' "${failure}" >"${test_root}/${failure}.log" 2>&1; then
    printf 'macOS packaging unexpectedly accepted %s service payload\n' "${failure}" >&2
    exit 1
  fi
  [[ ! -s "${sign_log}" ]]
  cmp "${test_root}/accepted-helper" "${app_dir}/Contents/MacOS/zenclash-service"
  [[ "$(cat "${app_dir}/preserved-marker")" == 'preserve existing bundle' ]]
done

# A cross-compiled bundle whose binaries are not actually Intel must be rejected.
for wrong in service gui; do
  rm -f "${mock_target}/x86_64-apple-darwin/release/zenclash-service"
  rm -f "${mock_target}/x86_64-apple-darwin/release/zenclash"
  : >"${sign_log}"
  result=0
  if [[ "${wrong}" == gui ]]; then
    MOCK_GUI_ARCH=arm64 run_build x86_64 x86_64-apple-darwin x86_64 \
      >"${test_root}/wrong-arch.log" 2>&1 || result=$?
  else
    run_build x86_64 x86_64-apple-darwin arm64 \
      >"${test_root}/wrong-arch.log" 2>&1 || result=$?
  fi
  if [[ "${result}" -eq 0 ]]; then
    printf 'macOS packaging unexpectedly accepted a non-Intel cross-compiled %s\n' "${wrong}" >&2
    exit 1
  fi
  [[ ! -s "${sign_log}" ]]
  cmp "${test_root}/accepted-helper" "${app_dir}/Contents/MacOS/zenclash-service"
done
# An Intel host cannot produce an arm64 bundle; it can still cross-compile x86_64.
rm -f "${mock_target}/aarch64-apple-darwin/release/zenclash-service"
rm -f "${mock_target}/aarch64-apple-darwin/release/zenclash"
: >"${sign_log}"
if MOCK_HOST_ARCH=x86_64 run_build arm64 aarch64-apple-darwin arm64 \
  >"${test_root}/host-arch.log" 2>&1; then
  echo 'macOS packaging unexpectedly built arm64 on an Intel host' >&2
  exit 1
fi
grep -Fq 'requires an Apple Silicon host' "${test_root}/host-arch.log"
[[ ! -s "${sign_log}" ]]
printf 'macOS helper payload regression test passed (arm64 + x86_64, no bundled core)\n'
