-- Settings UI for customkeymapper: TouchMenu sub-items, key capture, action picker.
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("lib/customkeymapper_i18n").gettext
local T = require("ffi/util").template
local helpers = require("lib/ckm_helpers")

local M = {}
local shared, KEYNAMES, ACTION_TITLES, KOACTIONS
local list_input_devices = helpers.list_input_devices

local function describe_action(spec)
    if not spec then return _("mapper.none") end
    if spec.dispatcher == "page_jmp" then
        return spec.value and spec.value == -1 and _("action.page_backward") or _("action.page_forward")
    end
    if spec.dispatcher then
        return _(ACTION_TITLES[spec.dispatcher] or spec.dispatcher)
    end
    return _("mapper.none")
end

local function describe_mapping(code, spec)
    local name = KEYNAMES.by_code[code] or ("KEY_" .. tostring(code))
    return T("%1  ->  %2", name, describe_action(spec))
end

function M:addToMainMenu(menu_items)
    menu_items.custom_key_mapper = {
        sorting_hint = "setting",
        text = _("mapper.title"),
        sub_item_table_func = function() return self:genMenuItems() end,
    }
end

function M:genMenuItems()
    local items = {}
    table.insert(items, {
        text_func = function() return T(_("mapper.device"), shared.cfg.device or "?") end,
        sub_item_table_func = function() return self:genDeviceMenu() end,
    })
    table.insert(items, {
        text = _("mapper.map_button"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu)
            self:startCapture(touchmenu)
        end,
    })
    table.insert(items, {
        text = _("mapper.choose_key"),
        keep_menu_open = true,
        sub_item_table_func = function() return self:genKeyList() end,
    })
    for code, spec in pairs(shared.cfg.actions) do
        table.insert(items, {
            text_func = function() return describe_mapping(code, spec) end,
            sub_item_table_func = function() return self:genMappingMenu(code) end,
            ignored_by_menu_search = true,
        })
    end
    if next(shared.cfg.actions) == nil then
        table.insert(items, {
            text = _("mapper.none_mapped"),
            enabled = false,
        })
    end
    items.refresh_func = function() return self:genMenuItems() end
    return items
end

function M:genDeviceMenu()
    local items = {}
    for i, dev in ipairs(list_input_devices()) do
        table.insert(items, {
            text = dev.usb and T("%1  [%2]  (USB)", dev.name, dev.ev) or T("%1  [%2]", dev.name, dev.ev),
            callback = function()
                shared.cfg.device = "/dev/input/" .. dev.ev
                self:saveCfg()
                UIManager:show(InfoMessage:new{
                    text = T(_("mapper.device_set"), shared.cfg.device), timeout = 2,
                })
            end,
        })
    end
    return items
end

-- List every known key, common ones first, so a binding can be made without pressing.
function M:genKeyList()
    local items = {}
    for i, k in ipairs(KEYNAMES.list) do
        table.insert(items, {
            text = T("%1  (%d)", k.name, k.code),
            keep_menu_open = true,
            callback = function(touchmenu)
                shared.captured_code = k.code
                shared.capture_tm = touchmenu
                shared.unwind_depth = #touchmenu.item_table_stack - 1
                self:pushActionPicker(touchmenu, shared.unwind_depth)
            end,
        })
    end
    return items
end

function M:genMappingMenu(code)
    local items = {
        {
            text = _("mapper.change_action"),
            keep_menu_open = true,
            callback = function(touchmenu)
                shared.captured_code = code
                shared.capture_tm = touchmenu
                shared.unwind_depth = #touchmenu.item_table_stack - 1
                self:pushActionPicker(touchmenu, shared.unwind_depth)
            end,
        },
        {
            text = _("mapper.delete_mapping"),
            keep_menu_open = true,
            callback = function(touchmenu)
                shared.cfg.actions[code] = nil
                self:saveCfg()
                -- Official way back: pop one level and let the parent's
                -- refresh_func rebuild it so the list shows the latest state.
                if touchmenu then
                    local stack = touchmenu.item_table_stack
                    local parent = stack and stack[#stack]
                    if parent then parent.needs_refresh = true end
                    touchmenu:backToUpperMenu()
                end
                UIManager:show(InfoMessage:new{ text = _("mapper.mapping_removed"), timeout = 2 })
            end,
        },
    }
    return items
end

function M:startCapture(touchmenu)
    shared.capture_next = true
    shared.capture_tm = touchmenu
    shared.capture_depth = #touchmenu.item_table_stack
    if shared.capture_msg then UIManager:close(shared.capture_msg) end
    shared.capture_msg = UIManager:show(InfoMessage:new{
        text = _("mapper.press_hint"), timeout = 8,
    })
end

function M:afterCapture(code)
    shared.captured_code = code
    if shared.capture_msg then
        UIManager:close(shared.capture_msg)
        shared.capture_msg = nil
    end
    if shared.capture_tm then
        shared.unwind_depth = shared.capture_depth
        self:pushActionPicker(shared.capture_tm, shared.unwind_depth)
    end
end

-- Build the action picker: curated paging/display first, then every KOReader
-- Dispatcher action grouped by the same context gestures use (General/Reader/...).
function M:genActionGroups()
    local groups = {}
    groups[#groups+1] = {
        text = T("%1  (%2)", _("action.paging"), "4"),
        sub_item_table_func = function() return self:actionItems({
            { title = "action.page_forward", spec = { dispatcher = "page_jmp", value = 1 } },
            { title = "action.page_backward", spec = { dispatcher = "page_jmp", value = -1 } },
            { title = "First page", spec = { dispatcher = "first_page" } },
            { title = "Last page", spec = { dispatcher = "last_page" } },
        }) end,
    }
    groups[#groups+1] = {
        text = T("%1  (%2)", _("action.display"), "3"),
        sub_item_table_func = function() return self:actionItems({
            { title = "Full screen refresh", spec = { dispatcher = "full_refresh" } },
            { title = "Toggle night mode", spec = { dispatcher = "night_mode" } },
            { title = "Toggle frontlight", spec = { dispatcher = "toggle_frontlight" } },
        }) end,
    }
    if type(KOACTIONS) == "table" then
        for si, section in ipairs(KOACTIONS) do
            local items = {}
            for ai, a in ipairs(section.actions or {}) do
                items[#items+1] = { title = a.title, spec = { dispatcher = a.action } }
            end
            if #items > 0 then
                groups[#groups+1] = {
                    text = T("%1  (%2)", _(section.section or "action.more"), tostring(#items)),
                    sub_item_table_func = function() return self:actionItems(items) end,
                }
            end
        end
    end
    return groups
end

function M:actionItems(items)
    local sub = {}
    for i, a in ipairs(items) do
        sub[#sub+1] = {
            text = _(a.title),
            keep_menu_open = true,
            callback = function() self:assignAction(a) end,
        }
    end
    return sub
end

function M:pushActionPicker(touchmenu, depth)
    local items = self:genActionGroups()
    table.insert(touchmenu.item_table_stack, touchmenu.item_table)
    touchmenu.item_table = items
    touchmenu:updateItems(1)
end

-- Back to the "mapper.title" list at `depth` and rebuild it so the
-- latest mappings are always shown after an edit.
function M:unwindTo(touchmenu, depth)
    if not touchmenu then return end
    while #touchmenu.item_table_stack > depth do
        touchmenu.item_table = table.remove(touchmenu.item_table_stack)
    end
    touchmenu.item_table = self:genMenuItems()
    touchmenu:updateItems(1)
end

function M:assignAction(action)
    local code = shared.captured_code
    if code then
        shared.cfg.actions[code] = action.spec
        self:saveCfg()
        self:unwindTo(shared.capture_tm, shared.unwind_depth)
        local keyname = KEYNAMES.by_code[code] or ("KEY_" .. tostring(code))
        UIManager:show(InfoMessage:new{
            text = T(_("mapper.mapped"), keyname, describe_action(action.spec)), timeout = 2,
        })
    end
end

function M:showMappings()
    local lines = { T(_("mapper.device"), shared.cfg.device or "?") }
    for code, spec in pairs(shared.cfg.actions) do
        table.insert(lines, describe_mapping(code, spec))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 12 })
end

-- Inject the plugin's shared state + static key/action tables, then merge the
-- methods onto the plugin class so they can be called as `self:method()`.
function M.attach(plugin_class, shared_table, deps)
    shared = shared_table
    KEYNAMES = deps.KEYNAMES
    ACTION_TITLES = deps.ACTION_TITLES
    KOACTIONS = deps.KOACTIONS
    for k, v in pairs(M) do
        if type(v) == "function" and k ~= "attach" then
            plugin_class[k] = v
        end
    end
end

return M
