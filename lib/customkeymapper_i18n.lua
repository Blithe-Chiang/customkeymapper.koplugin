-- customkeymapper_i18n.lua
-- Translation loader for plugin-specific strings (bookshelf-style).
-- Returns a translation function that checks the plugin's locale/<lang>.po
-- first, then falls back to KOReader's gettext. It does NOT modify the global
-- gettext module, so it can't interfere with KOReader's own translations.
--
-- Usage in main.lua:
--   local _ = require("lib/customkeymapper_i18n").gettext
--
-- To add a language:
--   1. Copy locale/zh_CN.po -> locale/<lang>.po
--   2. Fill in the msgstr values.
--   3. Done -- no code changes needed.

local logger = require("logger")

-- We live in lib/, but the .po files live in the plugin root's locale/ dir.
-- Strip a trailing "lib/" so the locale path resolves to the root.
local _dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")
local _base = (_dir:gsub("lib/$", ""))

-- Minimal .po parser (msgid/msgstr, with continuation and basic escapes).
local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local map, msgid, msgstr, in_id, in_str = {}, nil, nil, false, false
    local function flush()
        if msgid and msgstr and msgid ~= "" and msgstr ~= "" then
            map[msgid] = msgstr
        end
        msgid, msgstr, in_id, in_str = nil, nil, false, false
    end
    local function unescape(s)
        return s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
    end
    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line:match("^#") or line == "" then
            if line == "" then flush() end
        elseif line:match('^msgid%s+"') then
            flush()
            msgid  = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id, in_str = true, false
        elseif line:match('^msgstr%s+"') then
            msgstr = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_str, in_id = true, false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_id  and msgid  then msgid  = msgid  .. cont end
            if in_str and msgstr then msgstr = msgstr .. cont end
        end
    end
    flush()
    f:close()
    return map
end

local function detectLang()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then return lang end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    lang = lc:match("^([a-zA-Z_]+)")
    return lang or "en"
end

local ok_ko, ko_gettext = pcall(require, "gettext")
if not ok_ko then ko_gettext = function(t) return t end end

local function try(name)
    local path = _base .. "locale/" .. name .. ".po"
    local t = parsePO(path)
    if t and next(t) then
        logger.dbg("customkeymapper i18n: loaded " .. path)
        return t
    end
end

-- English is always the fallback language: load en.po unconditionally and try
-- to overlay the current language's .po on top of it. Missing keys thus fall
-- back to English, then to KOReader's gettext (for core action titles).
local en_po = try("en")
local translations = en_po
local lang = detectLang()
if lang ~= "en" and lang ~= "en_US" then
    local cur = try(lang) or (function()
        local prefix = lang:match("^([a-zA-Z]+)")
        if prefix and prefix ~= lang then return try(prefix) end
    end)()
    if cur then
        local merged = {}
        for k, v in pairs(en_po or {}) do merged[k] = v end  -- en as base
        for k, v in pairs(cur) do merged[k] = v end          -- lang overrides
        translations = merged
    end
end

-- Translation function: current-language .po (with en base) first, then KOReader gettext.
local function gettext(msgid)
    if translations then
        local t = translations[msgid]
        if t then return t end
    end
    return ko_gettext(msgid)
end

local function ngettext(s, _p, _n)
    return ko_gettext(s)  -- plural support not used by this plugin yet
end

return {
    gettext  = gettext,
    ngettext = ngettext,
    getLang  = detectLang,
}
