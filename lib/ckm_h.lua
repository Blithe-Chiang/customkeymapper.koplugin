-- FFI declarations for the customkeymapper native helper (lib/ckm_input.so).
--
-- Keep this file in sync with src/ckm_input.c and ckm.map.  The C side exports
-- only ckm_* symbols, so the declarations here are the plugin's stable ABI.
local ffi = require("ffi")

ffi.cdef[[
int ckm_abi_version(void);
int ckm_load_hid(const char *ko_dir);
int ckm_unload_hid(void);
]]

-- ABI version the plugin expects; bump together with CKM_ABI_VERSION in C.
return {
    abi_version = 1,
}
