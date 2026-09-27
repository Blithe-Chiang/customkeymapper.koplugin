-- Comprehensive Linux EV_KEY names (0-255 keyboard + 256-351 BTN), ordered so
-- the ones most useful with a page-turner / remote appear first. `list` is the
-- display order; `by_code` is a code -> name map for labelling existing maps.
local list = {}
local by_code = {}

local function add(code, name)
    by_code[code] = name
    list[#list+1] = { code = code, name = name }
end

-- Common / page-turner friendly first.
add(103, "UP"); add(108, "DOWN"); add(104, "PAGEUP"); add(109, "PAGEDOWN")
add(105, "LEFT"); add(106, "RIGHT"); add(28, "ENTER"); add(15, "TAB")
add(1, "ESC"); add(57, "SPACE"); add(102, "HOME"); add(107, "END")
add(110, "INSERT"); add(111, "DEL"); add(158, "BACK"); add(159, "FORWARD")
add(173, "REFRESH"); add(164, "PLAYPAUSE"); add(163, "NEXTSONG")
add(165, "PREVSONG"); add(166, "STOP"); add(114, "VOL-"); add(115, "VOL+")
add(116, "POWER"); add(139, "MENU"); add(217, "SEARCH"); add(63, "F5")
add(272, "BTN_LEFT"); add(273, "BTN_RIGHT"); add(274, "BTN_MIDDLE")
add(275, "BTN_SIDE"); add(276, "BTN_EXTRA")

-- Top row / digits.
for c, n in pairs({[2]="1",[3]="2",[4]="3",[5]="4",[6]="5",[7]="6",[8]="7",[9]="8",[10]="9",[11]="0"}) do add(c,n) end
-- Letters.
local letters = {[16]="Q",[17]="W",[18]="E",[19]="R",[20]="T",[21]="Y",[22]="U",[23]="I",[24]="O",[25]="P",
    [30]="A",[31]="S",[32]="D",[33]="F",[34]="G",[35]="H",[36]="J",[37]="K",[38]="L",
    [44]="Z",[45]="X",[46]="C",[47]="V",[48]="B",[49]="N",[50]="M"}
for c,n in pairs(letters) do add(c,n) end
-- Punctuation / modifiers.
add(39, ";"); add(40, "'"); add(51, ","); add(52, "."); add(53, "/"); add(26, "["); add(27, "]")
add(43, "\\"); add(12, "-"); add(13, "="); add(41, "`"); add(29, "LCTRL"); add(97, "RCTRL")
add(42, "LSHIFT"); add(54, "RSHIFT"); add(56, "LALT"); add(100, "RALT"); add(125, "LMETA"); add(126, "RMETA")
add(58, "CAPS"); add(69, "NUMLOCK"); add(70, "SCROLLLOCK")
-- Function keys.
add(59,"F1"); add(60,"F2"); add(61,"F3"); add(62,"F4"); add(64,"F6"); add(65,"F7"); add(66,"F8")
add(67,"F9"); add(68,"F10"); add(87,"F11"); add(88,"F12")
-- Keypad.
for c,n in pairs({[71]="KP7",[72]="KP8",[73]="KP9",[74]="KP-",[75]="KP4",[76]="KP5",[77]="KP6",
    [78]="KP+",[79]="KP1",[80]="KP2",[81]="KP3",[82]="KP0",[83]="KP.",[96]="KPENTER",[117]="KPEQ"}) do add(c,n) end
-- Navigation / media extra.
add(119,"PAUSE"); add(127,"COMPOSE"); add(128,"STOPCD"); add(129,"AGAIN"); add(130,"PROPS")
add(131,"UNDO"); add(132,"FRONT"); add(133,"COPY"); add(134,"OPEN"); add(135,"PASTE")
add(136,"FIND"); add(137,"CUT"); add(138,"HELP"); add(140,"CALC"); add(142,"SLEEP")
add(150,"WWW"); add(161,"EJECT"); add(176,"EDIT"); add(177,"SCROLLUP"); add(178,"SCROLLDOWN")
add(179,"KPL"); add(180,"KPR")
-- Buttons (gamepad/mouse upper range).
for c,n in pairs({[277]="BTN_FORWARD",[278]="BTN_BACK",[279]="BTN_TASK",[288]="BTN_TRIGGER",
    [289]="BTN_THUMB",[290]="BTN_THUMB2",[291]="BTN_TOP",[292]="BTN_TOP2",[293]="BTN_PINKIE",
    [294]="BTN_BASE",[295]="BTN_BASE2",[296]="BTN_BASE3",[297]="BTN_BASE4",[298]="BTN_BASE5",
    [299]="BTN_BASE6",[304]="BTN_A",[305]="BTN_B",[306]="BTN_C",[307]="BTN_X",[308]="BTN_Y",
    [309]="BTN_Z",[310]="BTN_TL",[311]="BTN_TR",[312]="BTN_TL2",[313]="BTN_TR2",
    [314]="BTN_SELECT",[315]="BTN_START",[316]="BTN_MODE",[317]="BTN_THUMBL",[318]="BTN_THUMBR"}) do add(c,n) end

return { list = list, by_code = by_code }
