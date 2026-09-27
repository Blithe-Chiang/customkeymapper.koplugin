local Device = require("device")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Split-out components (settings UI + Kindle USB HID/hotplug).
local ckm_ui = require("lib/ckm_ui")
local ckm_hotplug = require("lib/ckm_hotplug")

-- Resolve our own directory from the file being loaded, so the plugin keeps
-- working when it is installed (or cloned) under another directory name instead
-- of assuming plugins/customkeymapper.koplugin/. KOReader loads plugins with
-- dofile/loadfile, so the chunk source is "@<dir>/main.lua".
-- (self.path - used for lib/ckm_input.so in ckm_hotplug.lua - only exists once
-- the plugin instance is built in init(), too late for the tables read below.)
local PLUGIN_DIR = (function()
    -- getinfo(1) must report *this* chunk: wrap it in a closure so level 1 is the
    -- Lua function below rather than pcall (which would report "=[C]").
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    local dir = ok and info and info.source and info.source:match("^@(.*)/[^/]*$")
    if dir and dir ~= "" then return dir end
    -- Last resort only: unreachable for file-loaded plugins.
    return "plugins/customkeymapper.koplugin"
end)()

-- keymap.lua is only the *seed* (defaults on first run). Afterwards the plugin
-- persists the binding in KOReader settings, and edits happen through the UI.
local keymap_path = PLUGIN_DIR .. "/keymap.lua"

-- Comprehensive key-name table (common keys first, all keys listed).
local KEYNAMES = dofile(PLUGIN_DIR .. "/keynames.lua")
-- Static KOReader Dispatcher action list (no-arg actions), generated from
-- frontend/dispatcher.lua so no KOReader source is patched.
local KOACTIONS = dofile(PLUGIN_DIR .. "/koreader_actions.lua")

-- action -> human title (matches the action list). page_jmp needs its value to
-- disambiguate forward/backward, handled separately in describe_action.
local ACTION_TITLES = {}
for gi, section in ipairs(KOACTIONS) do
    for ai, a in ipairs(section.actions or {}) do
        ACTION_TITLES[a.action] = a.title
    end
end

-- Shared mutable state. KOReader instantiates this plugin once per context
-- (reader + filemanager), so per-instance fields would not be shared between
-- the menu (which starts a capture) and the input hook. This table keeps them
-- in sync regardless of which instance runs.
local shared = {
    hook_registered = false,
    capture_next = false,
    capture_tm = nil,
    capture_depth = 0,
    unwind_depth = 0,
    captured_code = nil,
    capture_msg = nil,
    cfg = nil,
    -- Native helper + USB HID modules (Kindle hotplug support).
    ckm = nil,               -- ffi library handle for lib/ckm_input.so
    hid_attempted = false,   -- ckm_load_hid already attempted (both instances share this)
    hid_loaded = false,
    hid_setup = false,       -- one-time (per process) hotplug setup already done
    open_devices = {},       -- /dev/input/eventN -> true, devices this plugin opened
    poll_active = false,
    poll_stopped = false,
}

local CustomKeyMapper = WidgetContainer:extend{
    name = "custom_key_mapper",
    is_doc_only = false,
}

------------------------------------------------------------------------------
-- Config persistence (KOReader settings; keymap.lua is just the seed)
------------------------------------------------------------------------------
function CustomKeyMapper:loadCfg()
    local cfg = G_reader_settings:readSetting("custom_key_mapper")
    if cfg and type(cfg) == "table" then
        cfg.actions = cfg.actions or {}
        return cfg
    end
    local ok, seed = pcall(dofile, keymap_path)
    if ok and type(seed) == "table" then
        seed.actions = seed.actions or {}
        G_reader_settings:saveSetting("custom_key_mapper", seed)
        return seed
    end
    return { device = "/dev/input/event2", actions = {} }
end

function CustomKeyMapper:saveCfg()
    G_reader_settings:saveSetting("custom_key_mapper", shared.cfg)
end

------------------------------------------------------------------------------
-- Input mapping (input adjust hook)
------------------------------------------------------------------------------
local function trigger(action)
    if type(action) ~= "table" then return end
    if not action.dispatcher then return end
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher then
        local v = action.value
        pcall(Dispatcher.execute, Dispatcher, {[action.dispatcher] = v == nil and true or v})
    end
end

local function register_hook(self)
    Device.input:registerEventAdjustHook(function(this, ev)
        local cfg = shared.cfg
        if not cfg or not cfg.actions or ev.type ~= 1 then return end
        local v = ev.value
        local action = cfg.actions[ev.code]
        if v == 1 and shared.capture_next then
            shared.capture_next = false
            ev.value = -1
            self:afterCapture(ev.code)
        elseif action then
            if v == 1 then trigger(action) end
            ev.value = -1  -- swallow press/repeat/release so nothing else fires
        end
    end)
end

------------------------------------------------------------------------------
-- Wire up the split-out components: UI methods + Kindle USB HID/hotplug.
------------------------------------------------------------------------------
ckm_ui.attach(CustomKeyMapper, shared, {
    KEYNAMES = KEYNAMES,
    KOACTIONS = KOACTIONS,
    ACTION_TITLES = ACTION_TITLES,
})
ckm_hotplug.attach(CustomKeyMapper, shared)

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------
function CustomKeyMapper:init()
    shared.cfg = self:loadCfg()
    shared.capture_next = false
    shared.capture_tm = nil
    shared.captured_code = nil
    self.ui.menu:registerToMainMenu(self)
    if not shared.hook_registered then
        shared.hook_registered = true
        register_hook(self)
    end
    -- Kindle-specific: self-load USB HID modules and keep up with hotplug.
    if Device:isKindle() then
        self:setupUsbHidSupport()
    end
end

return CustomKeyMapper
