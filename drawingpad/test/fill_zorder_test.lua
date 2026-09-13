--[[--
填充图层遮挡回归测试(v61w):
中层大灰点填 + 上层多个白路径填充,再画笔画触发区域重放——
灰填不得越出重放区盖掉高层白填(旧 _redrawRegion 整元素无裁剪重画的 bug)。
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

local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local canvas = newCanvas()
local function px(x, y) return canvas.canvas_bb:getPixel(x, y).a end

-- 中层(2):大面积灰色点填
canvas:_switchLayer(2)
canvas:_setTool("fill")
canvas.gray = 0.5
canvas:onTap(nil, { pos = { x = 270, y = 300 } })
check(canvas.layers[2][1] and canvas.layers[2][1].kind == "fill", "L2 tap fill committed")

-- 上层(3):4 个白色路径填充
canvas:_switchLayer(3)
canvas:_setTool("fill")
canvas:_toggleFillMode()
canvas.gray = 0.0
local spots = {
    { { 150, 250 }, { 220, 260 }, { 230, 320 }, { 160, 310 } },
    { { 250, 260 }, { 330, 270 }, { 340, 340 }, { 260, 330 } },
    { { 170, 350 }, { 260, 360 }, { 250, 430 }, { 180, 420 } },
    { { 300, 380 }, { 390, 390 }, { 380, 460 }, { 310, 450 } },
}
for _, s in ipairs(spots) do
    canvas:onPan(nil, { pos = { x = s[1][1], y = s[1][2] }, start_pos = { x = s[1][1], y = s[1][2] } })
    canvas:onPan(nil, { pos = { x = s[2][1], y = s[2][2] }, start_pos = { x = s[1][1], y = s[1][2] } })
    canvas:onPan(nil, { pos = { x = s[3][1], y = s[3][2] }, start_pos = { x = s[1][1], y = s[1][2] } })
    canvas:onPanRelease(nil, { pos = { x = s[4][1], y = s[4][2] } })
end
check(#canvas.layers[3] == 4, "4 white fills committed on L3")

-- 上层再画两笔(每次提交触发 _commitRegionReplay 区域重放)
canvas:_setTool("brush")
canvas.gray = 1.0
canvas.width = 4
canvas:onPan(nil, { pos = { x = 200, y = 290 }, start_pos = { x = 200, y = 290 } })
canvas:onPan(nil, { pos = { x = 220, y = 292 }, start_pos = { x = 200, y = 290 } })
canvas:onPanRelease(nil, { pos = { x = 240, y = 295 } })
canvas:onPan(nil, { pos = { x = 300, y = 400 }, start_pos = { x = 300, y = 400 } })
canvas:onPan(nil, { pos = { x = 320, y = 402 }, start_pos = { x = 300, y = 400 } })
canvas:onPanRelease(nil, { pos = { x = 340, y = 405 } })

-- 白填区内部保持白(255);笔画交叉处黑(0)
check(px(280, 300) == 255, "white fill 2 interior stays white, got " .. px(280, 300))
check(px(215, 385) == 255, "white fill 3 interior stays white, got " .. px(215, 385))
check(px(340, 420) == 255, "white fill 4 interior stays white, got " .. px(340, 420))
check(px(210, 292) < 60, "stroke ink visible on top")
-- 与全量重放一致性
canvas:_renderAll()
check(px(280, 300) == 255 and px(215, 385) == 255, "matches full replay after _renderAll")
canvas:onCloseWidget()

print("PASS: fill z-order region replay")
