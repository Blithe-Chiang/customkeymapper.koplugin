#!/usr/bin/env bash
# Package a KOReader-installable release tarball.
#
# The archive contains a single top-level directory, customkeymapper.koplugin/,
# so it can be unpacked straight into /mnt/us/koreader/plugins/. It holds the
# repository minus VCS metadata, the build-only librime_koreader submodule and
# dist/, plus a MANIFEST.sha256 of every file and a .sha256 sidecar next to the
# tarball.
#
# Usage: scripts/package-release.sh
#
# Overridable env:
#   CKM_LIBRARY   native helper to ship (default: lib/ckm_input.so for
#                 kindlepw2); it is always installed into the release as
#                 lib/ckm_input.so, which is the path the plugin loads
#   CKM_VERSION   override the version read from _meta.lua
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# The plugin is PW3-only: one ABI, one set of kernel modules.
readonly TARGET="kindlepw2"

fail() { echo "error: $*" >&2; exit 1; }

for arg in "$@"; do
    case "${arg}" in
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) fail "unknown argument: ${arg}" ;;
    esac
done

if command -v sha256sum >/dev/null 2>&1; then
    SHA256=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    SHA256=(shasum -a 256)
else
    fail "sha256sum or shasum is required"
fi
readonly SHA256

VERSION="${CKM_VERSION:-$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${ROOT_DIR}/_meta.lua" | head -1)}"
[[ -n "${VERSION}" ]] || fail "cannot parse version from _meta.lua"

LIBRARY="${CKM_LIBRARY:-${ROOT_DIR}/lib/ckm_input.so}"
[[ "${LIBRARY}" == /* ]] || LIBRARY="${ROOT_DIR}/${LIBRARY}"

readonly OUTPUT_DIR="${ROOT_DIR}/dist/release"
readonly ARCHIVE="${OUTPUT_DIR}/customkeymapper-${TARGET}-v${VERSION}.tar.gz"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ckm-release.XXXXXX")"
readonly STAGE_DIR
trap 'rm -rf "${STAGE_DIR}"' EXIT

required=(
    "_meta.lua"
    "main.lua"
    "keymap.lua"
    "keynames.lua"
    "koreader_actions.lua"
    "ckm.map"
    "README.md"
    "lib/ckm_input.so"
    "lib/ckm_h.lua"
    "lib/ckm_hotplug.lua"
    "lib/ckm_ui.lua"
    "lib/ckm_helpers.lua"
    "lib/customkeymapper_i18n.lua"
    "lib/modules/README.md"
    "lib/modules/SHA256SUMS"
    "lib/modules/hid.ko"
    "lib/modules/usbhid.ko"
    "lib/modules/mousedev.ko"
    "locale/en.po"
    "locale/zh_CN.po"
)
for path in "${required[@]}"; do
    [[ -f "${ROOT_DIR}/${path}" ]] || fail "missing release file: ${path}"
done
[[ -f "${LIBRARY}" ]] || fail "missing native library: ${LIBRARY} (build it first)"

# Never ship a helper that drifted from its source or from lib/ckm_h.lua.
"${SCRIPT_DIR}/check-artifacts.sh" --so "${LIBRARY}"

mkdir -p "${STAGE_DIR}/customkeymapper.koplugin" "${OUTPUT_DIR}"
tar -C "${ROOT_DIR}" \
    --exclude='./.git' --exclude='./.gitignore' --exclude='./.gitmodules' \
    --exclude='./dist' --exclude='./librime_koreader' \
    --exclude='./scripts/package-release.sh' --exclude='./MANIFEST.sha256' \
    --exclude='.DS_Store' --exclude='*.bak' --exclude='*.orig' \
    -cf - . \
    | tar -C "${STAGE_DIR}/customkeymapper.koplugin" -xf -

# The release always ships the helper under the path the plugin loads.
if [[ "${LIBRARY}" != "${ROOT_DIR}/lib/ckm_input.so" ]]; then
    cp "${LIBRARY}" "${STAGE_DIR}/customkeymapper.koplugin/lib/ckm_input.so"
fi

if find "${STAGE_DIR}" -type d \( -name .git -o -name librime_koreader \
        -o -name dist -o -name __pycache__ \) | grep -q .; then
    fail "release contains a build-only or VCS directory"
fi
if find "${STAGE_DIR}" -type f \( -name '.gitignore' -o -name '.gitmodules' \
        -o -name '.DS_Store' -o -name '*.log' -o -name '*.tmp' -o -name '*.bak' \
        -o -name '*.orig' \) | grep -q .; then
    fail "release contains VCS metadata or generated files"
fi

# Paths are relative to the plugin directory, so that
#   cd customkeymapper.koplugin && shasum -a 256 -c MANIFEST.sha256
# works in place (same convention as lib/modules/SHA256SUMS).
(
    cd "${STAGE_DIR}/customkeymapper.koplugin"
    find . -type f ! -name MANIFEST.sha256 | sed 's|^\./||' | LC_ALL=C sort \
        | while IFS= read -r file; do "${SHA256[@]}" "${file}"; done \
        > MANIFEST.sha256
)

tar -C "${STAGE_DIR}" -czf "${ARCHIVE}" customkeymapper.koplugin
(
    cd "${OUTPUT_DIR}"
    "${SHA256[@]}" "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE}").sha256"
)

echo "created ${ARCHIVE}"
cat "${ARCHIVE}.sha256"
echo
echo "install: unpack into /mnt/us/koreader/plugins/ (top level is customkeymapper.koplugin/)"
