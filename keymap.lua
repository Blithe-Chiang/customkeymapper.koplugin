-- Custom key mapping config.
--
-- This is the single file you edit to bind buttons of your input device to
-- KOReader actions. Restart KOReader (or use the plugin menu "Reload config")
-- after editing.
--
-- `device` is informational + used by the "Capture a button" helper to pick
-- which device to listen on. Matching is done by keycode, so in the common
-- single-keyboard case you can leave it as-is.
--
-- Each action is a small table with one of:
--   { dispatcher = "full_refresh" }                       -- a KOReader Dispatcher action
--   { dispatcher = "page_jmp", value = 1 }                -- Dispatcher action with a value
--
-- Useful Dispatcher actions: full_refresh, page_jmp (value +/-1 turns a page),
-- first_page, last_page, night_mode, toggle_frontlight, set_frontlight.
-- To discover a button's keycode, use the InputMonitor KUAL extension or the
-- plugin menu "Capture a button".
return {
    device = "/dev/input/event2",
    actions = {
        [103] = { dispatcher = "page_jmp", value = -1 },   -- 上  -> 上一页
        [108] = { dispatcher = "page_jmp", value = 1  },   -- 下  -> 下一页
        [15]  = { dispatcher = "full_refresh" },           -- square -> 全屏刷新
        -- [105] = { dispatcher = "first_page" },            -- left  -> 回到开头 (example)
        -- [106] = { dispatcher = "last_page" },             -- right -> 回到底部 (example)
    },
}
