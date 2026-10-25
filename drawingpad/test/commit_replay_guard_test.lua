--[[--
提交重放按元素相交细化(v63c)单测:
1. 上层可见有内容但与新笔区域不相交 → 提交零重放(_redrawRegion 不被调)
2. 上层元素 bbox 与新笔区域相交 → 提交触发一次重放
3. 上层无可见内容 → 零重放(旧行为回归)
运行:cd 模拟器 koreader 目录 && ./luajit plugins/drawingboard.koplugin/drawingpad/test/commit_replay_guard_test.lua
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

local DrawingCanvas = require("drawingpad.drawing_canvas")

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local passed = 0
local function section(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print(err)
        print(string.format("RESULT: %d passed, FAILED at above", passed))
        os.exit(1)
    end
end

local function newCanvas()
    return DrawingCanvas:new{ on_close = function() end }
end

-- 在指定层落一个矩形元素(经 _switchLayer 正确重定向 elements/undo 引用)
local function commitRect(canvas, x0, y0, x1, y1)
    canvas:_setTool("rect")
    canvas:onPan(nil, { pos = { x = x0, y = y0 }, start_pos = { x = x0, y = y0 } })
    canvas:onPanRelease(nil, { pos = { x = x1, y = y1 } })
    return canvas.elements[#canvas.elements]
end

-- 1. 上层有元素但不相交 → 零重放
section("upper layer non-intersecting: no replay on commit", function()
    local canvas = newCanvas()
    canvas:_switchLayer(3)
    commitRect(canvas, 10, 10, 60, 60) -- 上层左上角
    canvas:_switchLayer(2)
    local n = 0
    local orig = canvas._redrawRegion
    canvas._redrawRegion = function(...) n = n + 1 return orig(...) end
    commitRect(canvas, 200, 200, 300, 300) -- 中部,不相交
    canvas._redrawRegion = orig
    check(n == 0, "expected 0 replays, got " .. n)
    canvas:onCloseWidget()
end)

-- 2. 上层元素相交 → 有重放
section("upper layer intersecting: replay happens", function()
    local canvas = newCanvas()
    canvas:_switchLayer(3)
    commitRect(canvas, 250, 250, 400, 400)
    canvas:_switchLayer(2)
    local n = 0
    local orig = canvas._redrawRegion
    canvas._redrawRegion = function(...) n = n + 1 return orig(...) end
    commitRect(canvas, 200, 200, 300, 300) -- 与上层 250..400 相交
    canvas._redrawRegion = orig
    check(n >= 1, "expected >=1 replay, got " .. n)
    canvas:onCloseWidget()
end)

-- 3. 上层无可见内容 → 零重放(旧行为)
section("upper layers empty: no replay", function()
    local canvas = newCanvas()
    canvas:_switchLayer(2)
    local n = 0
    local orig = canvas._redrawRegion
    canvas._redrawRegion = function(...) n = n + 1 return orig(...) end
    commitRect(canvas, 100, 100, 200, 200)
    canvas._redrawRegion = orig
    check(n == 0, "expected 0 replays, got " .. n)
    canvas:onCloseWidget()
end)

print(string.format("RESULT: %d passed", passed))
