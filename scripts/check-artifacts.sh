#!/usr/bin/env bash
# Guard the committed native artifacts against silent drift.
#
#   lib/modules/*.ko  must match lib/modules/SHA256SUMS
#   lib/ckm_input.so  must pass the librime_koreader ABI check for kindlepw2 and
#                     export exactly the ckm_* symbols lib/ckm_h.lua declares
#   src/ckm_input.c   CKM_ABI_VERSION must match lib/ckm_h.lua abi_version
#
# Usage: scripts/check-artifacts.sh [--so PATH] [--rebuild]
#
#   --so PATH   check another helper instead of lib/ckm_input.so (used by
#               scripts/package-release.sh for freshly built targets)
#   --rebuild   rebuild with zig straight into lib/ckm_input.so (the committed
#               path, so the bytes are comparable) and diff it against the file
#               that was there. Identical bytes mean the artifact is in sync;
#               otherwise the fresh build is kept and the script exits 1.
#               Needs zig and the librime_koreader submodule. A different zig
#               version can also make the bytes differ. Not valid with --so.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# PW3-only (kindlepw2): both the committed helper and lib/modules/*.ko target
# kernel 3.0.35-lab126 on softfp ARMv7.
readonly TARGET="kindlepw2"
readonly DEFAULT_SO="${PLUGIN_DIR}/lib/ckm_input.so"

SO="${CKM_SO:-}"
REBUILD=0
while (( $# )); do
    case "$1" in
        --rebuild) REBUILD=1 ;;
        --so)
            shift
            [[ -n "${1:-}" ]] || { echo "error: --so needs a path" >&2; exit 2; }
            SO="$1"
            ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
SO="${SO:-${DEFAULT_SO}}"
[[ "${SO}" == /* ]] || SO="${PLUGIN_DIR}/${SO}"
readonly SO
REL_SO="${SO#"${PLUGIN_DIR}/"}"
readonly REL_SO

readonly FFI="${PLUGIN_DIR}/lib/ckm_h.lua"
readonly SRC="${PLUGIN_DIR}/src/ckm_input.c"
readonly MODULE_DIR="${PLUGIN_DIR}/lib/modules"
readonly CHECKSUMS="${MODULE_DIR}/SHA256SUMS"

ok() { echo "ok: $*"; }
fail() { echo "error: $*" >&2; exit 1; }

if (( REBUILD )) && [[ "${SO}" != "${DEFAULT_SO}" ]]; then
    fail "--rebuild only works on ${DEFAULT_SO}: the rebuilt bytes embed the output path"
fi

if command -v shasum >/dev/null 2>&1; then
    SHA256=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then
    SHA256=(sha256sum)
else
    fail "shasum or sha256sum is required"
fi
readonly SHA256

readonly SUBMODULE_HINT="git -C ${PLUGIN_DIR} submodule update --init --recursive"

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

find_readelf() {
    local candidate
    for candidate in "${READELF:-}" llvm-readelf greadelf \
            /opt/homebrew/opt/llvm/bin/llvm-readelf readelf; do
        [[ -n "${candidate}" ]] || continue
        if [[ "${candidate}" == */* && -x "${candidate}" ]]; then
            echo "${candidate}"
            return
        fi
        command -v "${candidate}" 2>/dev/null && return
    done
    return 1
}

# 1. The kernel modules that ship with the plugin.
[[ -f "${CHECKSUMS}" ]] || fail "missing ${CHECKSUMS}"
(cd "${MODULE_DIR}" && "${SHA256[@]}" -c SHA256SUMS)
ok "lib/modules/*.ko match SHA256SUMS"

# 2. The cross-compiled helper still satisfies the target ABI.
[[ -f "${SO}" ]] || fail "missing ${SO}"
RIME_PROJ="$(resolve_checkout)" || fail \
"no librime_koreader checkout providing targets/${TARGET}.env
  fix: ${SUBMODULE_HINT}
  (or set RIME_PROJ to an existing librime_koreader checkout)"
readonly RIME_PROJ
[[ -f "${RIME_PROJ}/scripts/verify-elf.sh" ]] || fail \
    "verify-elf.sh not found under ${RIME_PROJ}; fix: ${SUBMODULE_HINT}"
"${RIME_PROJ}/scripts/verify-elf.sh" "${TARGET}" "${SO}"

READELF="$(find_readelf)" || fail "llvm-readelf or GNU readelf is required"
readonly READELF

# 3. Exported symbols == the C ABI declared for LuaJIT.
exported="$("${READELF}" --dyn-syms --wide "${SO}" | awk '
    $4 == "FUNC" && $5 == "GLOBAL" && $6 == "DEFAULT" && $7 != "UND" { print $8 }
' | sed -E 's/@.*$//' | sort -u)"
declared="$(sed -n '/ffi.cdef\[\[/,/\]\]/p' "${FFI}" | grep -oE 'ckm_[a-z0-9_]+' | sort -u)"

stray="$(printf '%s\n' "${exported}" | grep -vE '^ckm_' || true)"
[[ -z "${stray}" ]] || fail "lib/ckm_input.so exports symbols outside ckm_*: ${stray}"
if [[ "${exported}" != "${declared}" ]]; then
    echo "error: exported symbols and lib/ckm_h.lua disagree (declared vs exported)" >&2
    diff <(printf '%s\n' "${declared}") <(printf '%s\n' "${exported}") >&2 || true
    exit 1
fi
ok "lib/ckm_input.so exports $(printf '%s' "${exported}" | tr '\n' ' ')"

# 4. ABI version agreed by C and Lua.
c_abi="$(sed -nE 's/^[[:space:]]*#define[[:space:]]+CKM_ABI_VERSION[[:space:]]+([0-9]+).*/\1/p' "${SRC}" | head -1)"
lua_abi="$(sed -nE 's/.*abi_version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${FFI}" | head -1)"
[[ -n "${c_abi}" && -n "${lua_abi}" ]] || fail "cannot read CKM_ABI_VERSION / abi_version"
[[ "${c_abi}" == "${lua_abi}" ]] || fail \
    "CKM_ABI_VERSION=${c_abi} in src/ckm_input.c but abi_version=${lua_abi} in lib/ckm_h.lua"
ok "ABI version ${c_abi} matches lib/ckm_h.lua"

# 5. Optional: rebuild and compare byte for byte (same output path).
if (( REBUILD )); then
    backup="$(mktemp -t ckm_input)"
    cp "${SO}" "${backup}"
    "${SCRIPT_DIR}/build-ckm.sh" "${TARGET}" >/dev/null
    if cmp -s "${SO}" "${backup}"; then
        ok "rebuilt ${TARGET} artifact is byte-identical to ${REL_SO}"
        rm -f "${backup}"
    else
        echo "error: ${REL_SO} did not match a fresh ${TARGET} build" >&2
        echo "  committed: $("${SHA256[@]}" "${backup}" | awk '{print $1}')" >&2
        echo "  rebuilt:   $("${SHA256[@]}" "${SO}" | awk '{print $1}')" >&2
        echo "  ${SO} now holds the rebuilt file; the previous one is" >&2
        echo "  kept at ${backup}. Review the difference, then commit the artifact." >&2
        echo "  (a different zig version can also cause this; check \`zig version\`)" >&2
        exit 1
    fi
fi

echo "artifacts verified"
