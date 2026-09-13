--[[--
滑条触摸区回归测试:showValuePicker 的滑条命中区不得覆盖任何按键。
背景:旧版 hit_rect 四边各扩 scaleBySize(30),向下溢出压进预设数字按键的触摸区,
而手势事件按子控件顺序先到滑条层(slider_wrap 在 preset_bt 之前)→ 按键被抢触点
(用户实测所有属性设置弹窗的数字按键难触控)。修复后向下只扩到与按键的间隙边界。

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/slider_hit_test.lua
--]]

local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local UIManager = require("ui/uimanager")
local Screen = Device.screen
local components = require("drawingpad.components")

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

-- 收集 widget 树里的关键控件(只走子控件路径,跳过 show_parent 等回引防环)
local function collect(root)
    local slider_wrap, buttons = nil, {}
    local function visit(w, depth)
        if not w or depth > 12 or type(w) ~= "table" then
            return
        end
        if w.hitRect and w.onTapProgress then
            slider_wrap = w
        end
        if w.buttons_layout then -- ButtonTable:行数组里是 Button 实例
            for _, row in ipairs(w.buttons_layout) do
                for _, b in ipairs(row) do
                    buttons[#buttons + 1] = b
                end
            end
        end
        local kids = {}
        if w[1] then
            kids[#kids + 1] = w[1]
        end
        for i = 2, (w.length or #w) do
            kids[#kids + 1] = w[i]
        end
        if w.movable then
            kids[#kids + 1] = w.movable
        end
        for _, k in ipairs(kids) do
            visit(k, depth + 1)
        end
    end
    visit(root, 0)
    return slider_wrap, buttons
end

local function intersect(a, b)
    return a and b and a.x < b.x + b.w and b.x < a.x + a.w
        and a.y < b.y + b.h and b.y < a.y + b.h
end

local passed = 0
local function section(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print(err)
        print("RESULT: " .. passed .. " passed, FAILED at above")
        os.exit(1)
    end
end

-- 弹出值弹窗(stub show 捕获)并真实 paint(dimen 在 paint 时才更新)
local function buildPicker()
    local captured = {}
    local real_show = UIManager.show
    UIManager.show = function(ui, w)
        captured[#captured + 1] = w
        return w
    end
    components.showValuePicker{
        title = "T",
        value = 50,
        min = 0,
        max = 100,
        unit = "%",
    }
    UIManager.show = real_show
    local popup = captured[#captured]
    check(popup ~= nil, "popup captured")
    local ok, err = pcall(function() popup:paintTo(Screen.bb, 0, 0) end)
    check(ok, "popup paint: " .. tostring(err))
    return popup
end

section("picker 0-100: hit rect covers no button", function()
    local popup = buildPicker()
    local slider_wrap, buttons = collect(popup)
    check(slider_wrap ~= nil, "slider_wrap found")
    check(#buttons >= 10, "buttons found (step+preset+close), got " .. #buttons)
    local hit = slider_wrap.hitRect()
    check(hit ~= nil, "hit rect computed")
    for i, b in ipairs(buttons) do
        if b.dimen then
            check(not intersect(hit, b.dimen),
                "hit rect overlaps button #" .. i .. " (" .. tostring(b.text) .. ")")
        end
    end
    -- 修复语义:向下扩展恰好用完间隙(与 3*vertical_large 同量),不再多压按键
    popup:onCloseWidget()
end)

section("picker 1-800 (粗细域): hit rect covers no button", function()
    local captured = {}
    local real_show = UIManager.show
    UIManager.show = function(ui, w)
        captured[#captured + 1] = w
        return w
    end
    components.showValuePicker{ title = "T2", value = 400, min = 1, max = 800 }
    UIManager.show = real_show
    local popup = captured[#captured]
    local slider_wrap, buttons = collect(popup)
    local hit = slider_wrap.hitRect()
    for i, b in ipairs(buttons) do
        if b.dimen then
            check(not intersect(hit, b.dimen),
                "hit rect overlaps button #" .. i)
        end
    end
    popup:onCloseWidget()
end)

print("RESULT: all " .. passed .. " sections passed")
