--[[--
半透明笔迹实时代价基准:长笔迹分 10 段计时,验证每次 flush 代价只随"新段"增长、
与整笔长度无关(旧整笔重放方案为平方增长)。
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
local Blitbuffer = require("ffi/blitbuffer")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local W, H = 1072, 1448
local canvas = DrawingCanvas:new{ on_close = function() end }
canvas.canvas_w, canvas.canvas_h = W, H
canvas.canvas_bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
canvas.canvas_bb:fill(Blitbuffer.COLOR_WHITE)
canvas.layers = { {}, {}, {} }
canvas.elements = canvas.layers[2]
canvas.active_layer = 2
canvas.layer_visible = { true, true, true }
canvas.layer_alpha = { 1, 1, 1 }
canvas:_renderAll()

-- 2000 点长蛇形笔迹,width 60, alpha 0.5
local pts = {}
local x, y = 80, 100
for i = 1, 2000 do
    pts[i] = { x = x, y = y }
    x = x + 7
    if x > W - 100 then x = 80; y = y + 90 end
end

canvas.tool = "brush"
local s = { kind = "freehand", points = {}, width = 60, gray = 1, alpha = 0.5, tip = "circle" }
canvas._stroke = s

local NPHASE = 10
local per = math.floor(#pts / NPHASE)
local t0 = os.clock()
for i, p in ipairs(pts) do
    table.insert(s.points, p)
    canvas:_renderStrokeTail()
    canvas._stroke_region = canvas:_mergeRegions(canvas._stroke_region,
        canvas:_dirtyRegion(p.x, p.y, p.x, p.y, s.width + 2))
    if i % per == 0 then
        local t1 = os.clock()
        canvas:_flushStrokeRepaint()
        local dt = (os.clock() - t1) * 1000
        print(string.format('PHASE %2d pts=%4d flush=%6.1f ms', i / per, #s.points, dt))
    end
end
local t1 = os.clock()
canvas:_finishStroke(pts[#pts].x, pts[#pts].y)
print(string.format('FINISH commit = %.1f ms (incl. whole-stroke replay)', (os.clock() - t1) * 1000))
print(string.format('TOTAL draw loop = %.1f ms', (os.clock() - t0) * 1000))
os.exit(0)
