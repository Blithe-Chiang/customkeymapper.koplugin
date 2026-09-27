-- Kindle USB HID self-load + input hotplug for customkeymapper.
--
-- KOReader scans input devices once in Kindle:init(). The kernel emits a USB
-- HID /dev/input/eventN node only after the matching modules are inserted, so a
-- laser pointer plugged before KOReader started is missed. On top of that,
-- unplug/replug creates a fresh eventN that KOReader never opens.
--
-- We fix both inside the plugin: self-load hid/usbhid/mousedev with the native
-- helper (dropping the KindleLazy runtime dependency), then rescan and open any
-- button-like USB devices, and finally keep up with hotplug via the
-- EvdevInputInsert/Remove events *plus* a lightweight /proc poll fallback that
-- works even on kernels that do not raise those events for plain USB HID.
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local ffi = require("ffi")
local C = ffi.C
local bit = require("bit")
local lfs = require("libs/libkoreader-lfs")
require("ffi/posix_h")
require("ffi/fbink_input_h")
local ckm_h = require("lib/ckm_h")
local helpers = require("lib/ckm_helpers")
local list_input_devices = helpers.list_input_devices
local is_button_device = helpers.is_button_device

local M = {}
local shared

local function fbink_loadlib()
    local ok, lib = pcall(ffi.loadlib, "fbink_input", 1)
    if not ok then return nil end
    return lib
end

-- FBInk mask for "button-like, but not a bare mouse". INPUT_DPAD is deliberately
-- omitted: many USB HID page-turners expose a mouse interface that also reports
-- a full DPAD capability, and opening that node is redundant/unhelpful. The
-- keyboard node of such a device carries KEYBOARD/PAGINATION/HOME_BUTTON.
local BUTTON_MASK = bit.bor(C.INPUT_KEYBOARD, C.INPUT_PAGINATION_BUTTONS, C.INPUT_HOME_BUTTON)

-- Load lib/ckm_input.so once (both plugin instances share the process loaded
-- library). Returns true when the native helper is usable.
local function load_native(plugin_path)
    if shared.ckm then return true end
    if not plugin_path then return false end
    local so_path = plugin_path .. "/lib/ckm_input.so"
    local ok, lib = pcall(ffi.load, so_path)
    if not ok then
        logger.warn("[CKM] could not load native helper:", so_path, "-", lib)
        return false
    end
    if lib.ckm_abi_version and lib.ckm_abi_version() ~= ckm_h.abi_version then
        logger.warn("[CKM] native helper ABI mismatch, expected", ckm_h.abi_version)
        return false
    end
    shared.ckm = lib
    logger.dbg("[CKM] loaded native helper", so_path)
    return true
end

-- Insert hid.ko -> usbhid.ko -> mousedev.ko from lib/modules. Idempotent and
-- shared across instances; only attempts once per process.
local function ensure_hid_modules(plugin_path)
    if shared.hid_attempted then return shared.hid_loaded end
    shared.hid_attempted = true
    if not shared.ckm then return false end
    local ok, rc = pcall(shared.ckm.ckm_load_hid, plugin_path .. "/lib/modules")
    if ok and rc == 0 then
        shared.hid_loaded = true
        logger.info("[CKM] USB HID kernel modules loaded")
    else
        logger.warn("[CKM] ckm_load_hid failed:", ok and rc or tostring(rc))
    end
    return shared.hid_loaded
end

-- Open a device fd we already own from fbink, unless someone else opened it.
-- Dedups on the path (Input.opened_devices) and avoids leaking the extra fd.
local function try_open_device(fd, path, name)
    if not path or not fd then return false end
    if Device.input.opened_devices[path] then
        pcall(C.close, fd)
        return false
    end
    local ok, err = pcall(Device.input.fdopen, Device.input, fd, path, name)
    if ok then
        shared.open_devices[path] = true
        logger.dbg("[CKM] opened input device", name or "", "@", path)
        return true
    end
    -- fdopen failed: don't leak the fd fbink handed us.
    pcall(C.close, fd)
    logger.warn("[CKM] could not open", path, "-", err)
    return false
end

-- Probe a specific /dev/input path with FBInk and return its info if it looks
-- like a button-ish device. Returns nil when fbink is unavailable or unmatched.
local function check_keyboard(path)
    local FBInkInput = fbink_loadlib()
    if not FBInkInput or not FBInkInput.fbink_input_check then return nil end
    local dev = FBInkInput.fbink_input_check(path, BUTTON_MASK, 0, 0)
    if dev == nil then return nil end
    local info = nil
    if dev.matched then
        info = { fd = tonumber(dev.fd), path = ffi.string(dev.path), name = ffi.string(dev.name) }
    else
        -- fbink opened it only to probe capabilities; no one took the fd.
        if dev.fd > 0 then
            pcall(C.close, tonumber(dev.fd))
        end
    end
    C.free(dev)
    return info
end

-- Scan currently-present button-like USB devices and open them. The Kindle
-- default scan mask omits INPUT_KEYBOARD, so a laser pointer is never opened by
-- KoReader on its own; that is the core "already plugged at startup" fix.
local function open_button_devices_scan()
    local FBInkInput = fbink_loadlib()
    if not FBInkInput or not FBInkInput.fbink_input_scan then return end
    local dev_count = ffi.new("size_t[1]")
    local devices = FBInkInput.fbink_input_scan(BUTTON_MASK, 0, 0, dev_count)
    if devices ~= nil then
        for i = 0, tonumber(dev_count[0]) - 1 do
            local dev = devices[i]
            if dev.matched then
                local path = ffi.string(dev.path)
                -- Adopt this device even if KoReader already opened it, so the
                -- plugin owns its unplug/close/replug lifecycle.
                shared.open_devices[path] = true
                try_open_device(tonumber(dev.fd), path, ffi.string(dev.name))
            end
        end
        C.free(devices)
    end
end

-- Handler-based open. Reads /proc/bus/input/devices and opens any USB device
-- that looks button-like (kbd/sysrq). `devs` is optional: reuse the caller's
-- parsed list to avoid re-reading /proc.
local function open_button_devices_from_handlers(devs)
    devs = devs or list_input_devices()
    for _, d in ipairs(devs) do
        local path = "/dev/input/" .. d.ev
        if is_button_device(d) or (shared.cfg and shared.cfg.device == path) then
            -- Adopt all desired button devices so a later unplug clears their
            -- (possibly stale) bookkeeping and a replug reopens them.
            shared.open_devices[path] = true
            if not Device.input.opened_devices[path] then
                local ok, fd = pcall(Device.input.open, Device.input, path, d.name or path)
                if ok and fd then
                    logger.dbg("[CKM] opened button device", d.name or "", "@", path)
                elseif not ok then
                    logger.warn("[CKM] could not open", path, "-", fd)
                end
            end
        end
    end
end

local function open_configured_device()
    local path = shared.cfg and shared.cfg.device
    if not path or path == "?" then return end
    if lfs.attributes(path, "mode") == nil then
        -- Not present right now (e.g. the laser pointer is unplugged or its
        -- eventN changed after a replug). The poll/hotplug scan will open it
        -- by capability as soon as it exists, so this is informational only.
        logger.dbg("[CKM] configured device not present:", path)
        return
    end
    if Device.input.opened_devices[path] then return end
    local ok, fd = pcall(Device.input.open, Device.input, path, "customkeymapper")
    if ok and fd then
        shared.open_devices[path] = true
        logger.dbg("[CKM] opened configured device", path)
    elseif not ok then
        logger.warn("[CKM] could not open configured device", path, "-", fd)
    end
end

local function close_opened(path)
    if not shared.open_devices[path] then return end
    if Device.input.opened_devices[path] then
        Device.input:close(path)
    end
    -- The device node is confirmed gone. The native layer may have already
    -- dropped the fd (on ENODEV) and left Input.opened_devices[path] pointing at
    -- a stale number; clear it so a replug at the same path opens a fresh fd.
    Device.input.opened_devices[path] = nil
    shared.open_devices[path] = nil
end

-- Rerun the device scan after the HID modules settled, then open button-like
-- devices that the default scan missed. Idempotent: open scans/opens dedup on
-- Input.opened_devices, so repeated calls are cheap.
local function rescan_input()
    if not Device:isKindle() or not Device.input then return end
    -- NOTE: we intentionally do NOT re-run Device:openInputDevices() here. It
    -- opens every matching device (including pagination/page-turner ones) and
    -- never closes duplicate fds it gets from fbink, so repeated calls leak fds
    -- for already-open devices. The plugin's own scans below handle the button
    -- devices, and the native touchscreen/power devices were opened at boot.
    open_button_devices_scan()
    open_button_devices_from_handlers()
    open_configured_device()
end

-- Hotplug: kernel raised EvdevInputInsert/Remove (used for USB/UHID keyboards).
function M:onEvdevInputInsert(path)
    if not Device:isKindle() then return end
    -- Leave the kernel a beat to create the node before probing it.
    UIManager:scheduleIn(0.5, function()
        self:_onEvdevInputInsert(path)
    end)
end

function M:_onEvdevInputInsert(path)
    if not Device:isKindle() or not path then return end
    local info = check_keyboard(path)
    if info then
        shared.open_devices[info.path] = true
        try_open_device(info.fd, info.path, info.name)
        return
    end
    -- The configured device may not match a button class; open it directly.
    if shared.cfg and shared.cfg.device == path then
        shared.open_devices[path] = true
        if not Device.input.opened_devices[path] and lfs.attributes(path, "mode") ~= nil then
            local ok, fd = pcall(Device.input.open, Device.input, path, "customkeymapper")
            if ok and fd then
                logger.dbg("[CKM] opened configured device", path)
            elseif not ok then
                logger.warn("[CKM] could not open", path, "-", fd)
            end
        end
    else
        logger.dbg("[CKM] insert", path, "is not a button-like device")
    end
end

function M:onEvdevInputRemove(path)
    if not Device:isKindle() then return end
    UIManager:scheduleIn(0.5, function()
        self:_onEvdevInputRemove(path)
    end)
end

function M:_onEvdevInputRemove(path)
    if not shared.open_devices[path] then
        logger.dbg("[CKM] remove", path, "was not opened by this plugin")
        return
    end
    -- Make sure it is really gone before closing (another device could have unplugged).
    if lfs.attributes(path, "mode") ~= nil then
        logger.warn("[CKM] remove", path, "is still connected?!")
        return
    end
    logger.dbg("[CKM] closing input device", path)
    close_opened(path)
end

-- Fallback poll: some kernels don't emit EvdevInputInsert/Remove for plain USB
-- HID. Reading /proc/bus/input/devices every couple seconds is cheap and catches
-- new/removed event nodes without depending on the kernel uevent path.
local function poll_step()
    local existing = {}
    local devs = list_input_devices()
    for _, d in ipairs(devs) do
        existing["/dev/input/" .. d.ev] = true
    end

    -- Close devices we opened that disappeared.
    for path in pairs(shared.open_devices) do
        if not existing[path] then
            logger.dbg("[CKM] poll: closing disappeared device", path)
            close_opened(path)
        end
    end

    -- Open new button-like USB devices + the configured one (reuse parsed list).
    open_button_devices_from_handlers(devs)
end

local function poll_once()
    if shared.poll_stopped then return end
    local ok, err = pcall(poll_step)
    if not ok then
        logger.warn("[CKM] poll step error:", err)
    end
    if not shared.poll_stopped then
        UIManager:scheduleIn(2.0, poll_once)
    end
end

local function start_polling()
    if shared.poll_active then return end
    shared.poll_active = true
    shared.poll_stopped = false
    UIManager:scheduleIn(2.0, poll_once)
end

-- One-time (per process) Kindle setup: load the native helper, self-load the
-- HID modules, rescan input devices after they settle, and start hotplug polling.
function M:setupUsbHidSupport()
    if shared.hid_setup then return end
    shared.hid_setup = true

    local native_ok = load_native(self.path)
    if native_ok then
        ensure_hid_modules(self.path)
    end

    -- The kernel may need a moment to create the event node after usbhid binds;
    -- schedule two passes so a laser pointer plugged before KOReader started is
    -- picked up. rescan_input idempotently dedups on Input.opened_devices.
    UIManager:scheduleIn(0.2, function() pcall(rescan_input) end)
    UIManager:scheduleIn(0.9, function() pcall(rescan_input) end)

    -- Ideal path: kernel uevent -> EvdevInputInsert/Remove. Plus the /proc poll
    -- fallback so unplug/replug works even when those events never fire.
    start_polling()
end

function M:onExit()
    shared.poll_stopped = true
    shared.poll_active = false
end

-- Inject the plugin's shared state, then merge the methods onto the plugin class
-- so they can be called as `self:method()`.
function M.attach(plugin_class, shared_table)
    shared = shared_table
    for k, v in pairs(M) do
        if type(v) == "function" and k ~= "attach" then
            plugin_class[k] = v
        end
    end
end

return M
