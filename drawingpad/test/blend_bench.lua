--[[--
混合模式重放代价基准:模拟"多层半透明 multiply/dodge 叠加后收笔",
对 N 个相交元素做 _redrawRegion(收笔/撤销/移动预览的真实路径),计时对比。
运行(从 KOReader 模拟器根目录):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/blend_bench.lua
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
local shapes = require("drawingpad.shapes")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local W, H = 1072, 1448
local NLAYERS = 8
local RECT = 400 -- 每个元素 400×400,相邻错开 150px(大面积相交)

local function bench(mode)
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
    -- N 层实心矩形,依次错开(后续层压在前层上,模拟叠加)
    for i = 1, NLAYERS do
        local x0 = 60 + (i - 1) * 130
        local el = { kind = "rect", x0 = x0, y0 = 80, x1 = x0 + RECT, y1 = 80 + RECT,
            gray = 1.0, alpha = 0.5, blend = mode, filled = true }
        canvas:_cacheBBox(el)
        table.insert(canvas.elements, el)
        shapes.drawElement(canvas:_alphaBB(canvas.canvas_bb, el), el, Blitbuffer.gray(el.gray))
    end
    -- 重放整块相交区域(收笔 _redrawRegion 的真实路径)
    local region = { x = 60, y = 80, w = 60 + (NLAYERS - 1) * 130 + RECT - 60, h = RECT }
    -- 预热一次(JIT 编译)
    canvas:_redrawRegion(region)
    local t0 = os.clock()
    local REP = 3
    for _ = 1, REP do
        canvas:_redrawRegion(region)
    end
    local dt = (os.clock() - t0) * 1000 / REP
    print(string.format("BLEND-BENCH %s: redrawRegion(%d 层相交) = %.1f ms", mode, NLAYERS, dt))
    canvas.canvas_bb:free()
    canvas:onCloseWidget()
    return dt
end

bench("normal")
bench("multiply")
bench("dodge")
print("BLEND-BENCH DONE")
