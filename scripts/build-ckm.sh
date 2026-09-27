#!/usr/bin/env bash
# Cross-compile lib/ckm_input.so for a Kindle KOReader target with Zig.
#
# The Zig wrapper and the per-target ABI come from the librime_koreader
# submodule (pinned in .gitmodules), so this plugin is built with exactly the
# same ABI as the rime plugin:
#   kindlepw2 -> arm-linux-gnueabi.2.12, cortex_a9, softfp, -Wl,-z,lazy.
#
# Usage: scripts/build-ckm.sh
#
# Only the kindlepw2 (Kindle PW3) target is supported: the plugin ships PW3
# kernel modules (vermagic 3.0.35-lab126) and a softfp ARMv7 helper to match.
#
# Overridable env:
#   RIME_PROJ   librime_koreader checkout (default: ./librime_koreader, then
#               ../../rime/librime_koreader); needs targets/, toolchain/ and
#               scripts/verify-elf.sh
#   ZIG         path to zig (default: your PATH)
#   OUT         output .so (default: lib/ckm_input.so); relative paths are
#               relative to this plugin directory
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TARGET="kindlepw2"

fail() { echo "error: $*" >&2; exit 1; }

if (( $# > 1 )); then
    echo "usage: $0  (this plugin builds the kindlepw2/PW3 target only)" >&2
    exit 2
fi
[[ "${1:-${TARGET}}" == "${TARGET}" ]] || fail \
    "unsupported target '${1}': this plugin is PW3-only (kindlepw2); kindlehf was dropped
  the bundled lib/modules/*.ko are built for kernel 3.0.35-lab126 (PW3) and
  cannot be loaded by a newer hard-float Kindle, so no kindlehf build ships"

readonly SUBMODULE_HINT="git -C ${PLUGIN_DIR} submodule update --init --recursive"

# An explicit RIME_PROJ wins, then the pinned submodule, then the older
# sibling layout (kindle/rime/librime_koreader next to this checkout).
resolve_checkout() {
    local candidate
    for candidate in "${RIME_PROJ:-}" \
            "${PLUGIN_DIR}/librime_koreader" \
            "${PLUGIN_DIR}/../../rime/librime_koreader"; do
        [[ -n "${candidate}" && -f "${candidate}/targets/${TARGET}.env" ]] || continue
        (cd "${candidate}" && pwd)
        return 0
    done
    return 1
}

RIME_PROJ="$(resolve_checkout)" || fail \
"no librime_koreader checkout providing targets/${TARGET}.env
  looked at: \$RIME_PROJ, ${PLUGIN_DIR}/librime_koreader, ${PLUGIN_DIR}/../../rime/librime_koreader
  fix:       ${SUBMODULE_HINT}
  (or set RIME_PROJ to an existing librime_koreader checkout)"

readonly TARGET_CONFIG="${RIME_PROJ}/targets/${TARGET}.env"
# shellcheck disable=SC1090
source "${TARGET_CONFIG}"
for required in KOReader_TARGET ZIG_TARGET ZIG_MACHINE ZIG_CPU FLOAT_ABI GLIBC_MAX TARGET_CFLAGS; do
    [[ -n "${!required:-}" ]] || fail "${required} is missing from ${TARGET_CONFIG}"
done
[[ "${KOReader_TARGET}" == "${TARGET}" ]] || fail "target config name mismatch"

readonly RIME_TOOLCHAIN="${RIME_PROJ}/toolchain"
readonly VERIFY_ELF="${RIME_PROJ}/scripts/verify-elf.sh"

[[ -x "${RIME_TOOLCHAIN}/zig-cc" ]] || fail \
    "zig-cc not found under ${RIME_TOOLCHAIN}; fix: ${SUBMODULE_HINT}"
[[ -f "${VERIFY_ELF}" ]] || fail \
    "verify-elf.sh not found under ${RIME_PROJ}; fix: ${SUBMODULE_HINT}"

command -v "${ZIG:-zig}" >/dev/null 2>&1 || fail "zig is required (or set ZIG)"

readonly SRC="${PLUGIN_DIR}/src/ckm_input.c"
readonly MAP="${PLUGIN_DIR}/ckm.map"
OUT="${OUT:-${PLUGIN_DIR}/lib/ckm_input.so}"
[[ "${OUT}" == /* ]] || OUT="${PLUGIN_DIR}/${OUT}"
readonly OUT

[[ -f "${SRC}" ]] || fail "source not found: ${SRC}"
[[ -f "${MAP}" ]] || fail "version script not found: ${MAP}"
mkdir -p "$(dirname "${OUT}")"

export ZIG="${ZIG:-zig}"
export KRIME_ZIG_TARGET="${ZIG_TARGET}"
export KRIME_ZIG_MACHINE="${ZIG_MACHINE}"
export KRIME_ZIG_CPU="${ZIG_CPU}"

echo "Zig ${TARGET}: ${ZIG_TARGET} (${ZIG_CPU}, ${FLOAT_ABI})"
echo "toolchain: ${RIME_PROJ}"

# TARGET_CFLAGS is deliberately split into compiler arguments.
# shellcheck disable=SC2086
"${RIME_TOOLCHAIN}/zig-cc" \
    ${TARGET_CFLAGS} \
    -fPIC -fvisibility=hidden -O2 \
    -Wl,-z,lazy \
    -Wl,--version-script="${MAP}" \
    -shared "${SRC}" -o "${OUT}"

find_strip() {
    local candidate
    for candidate in "${LLVM_STRIP:-}" llvm-strip \
            /opt/homebrew/opt/llvm/bin/llvm-strip \
            /usr/local/opt/llvm/bin/llvm-strip; do
        [[ -n "${candidate}" ]] || continue
        if [[ "${candidate}" == */* && -x "${candidate}" ]]; then
            echo "${candidate}"
            return
        fi
        command -v "${candidate}" 2>/dev/null && return
    done
    return 1
}

if STRIP="$(find_strip)"; then
    "${STRIP}" --strip-unneeded "${OUT}"
else
    echo "warning: llvm-strip not found; leaving debug/symbol data in ${OUT}" >&2
fi

"${VERIFY_ELF}" "${TARGET}" "${OUT}"
echo "built ${OUT}"
if [[ "${OUT}" == "${PLUGIN_DIR}/lib/ckm_input.so" ]]; then
    echo "note: lib/ckm_input.so is committed so the plugin works right after a"
    echo "      clone; if you changed src/ckm_input.c, commit the rebuilt file too"
    echo "      (scripts/check-artifacts.sh --rebuild confirms it is in sync)."
fi
