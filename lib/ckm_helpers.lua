-- Pure helpers for customkeymapper: input device enumeration + heuristics.
-- No KOReader state is required here, so this is safe to require from any context.

-- Parse /proc/bus/input/devices into a list of { ev, name, usb, handlers }.
local function list_input_devices()
    local devs, bus, name, handlers = {}, nil, nil, nil
    for line in io.lines("/proc/bus/input/devices") do
        if line:match("^I: Bus=") then
            bus = line
        elseif line:match("^N: Name=") then
            name = line:match('Name="([^"]*)"')
        elseif line:match("^H: Handlers=") then
            handlers = line:match("^H: Handlers=(.*)")
            local ev = handlers:match("(event%d+)")
            if ev then
                local is_usb = bus ~= nil and not bus:match("Bus=0000")
                table.insert(devs, {
                    ev = ev,
                    name = name or ev,
                    usb = is_usb,
                    handlers = handlers or "",
                })
            end
        end
    end
    return devs
end

-- A USB-attached device that emits button-ish events (keyboard / d-pad /
-- page-turner). Built-in Kindle controllers are Bus=0000, so requiring `usb`
-- excludes them; the `kbd`/`sysrq` handlers are the tell-tale. We deliberately
-- do NOT treat a bare mouse interface as a button device: a USB HID page-turner
-- often exposes a keyboard node (the one we want) plus a redundant mouse node
-- (event3/mouse0) that would just add an extra fd to churn on replug.
local function is_button_device(dev)
    if not dev or not dev.usb then return false end
    local h = dev.handlers or ""
    -- A composite HID page-turner typically exposes a keyboard node (kbd only)
    -- plus a redundant mouse interface (kbd + mouse0). Skip anything that also
    -- has a mouse handler so we only track the button node, not the churny one.
    if h:find("mouse") ~= nil then return false end
    return h:find("kbd") ~= nil or h:find("sysrq") ~= nil
end

return {
    list_input_devices = list_input_devices,
    is_button_device = is_button_device,
}
