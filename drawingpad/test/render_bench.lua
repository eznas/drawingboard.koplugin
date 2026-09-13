-- 基准:多图形画布 _renderAll/_toggleLayerVisible 耗时分解
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
local shapes = require("drawingpad.shapes")
local Blitbuffer = require("ffi/blitbuffer")

local canvas = DrawingCanvas:new{ on_close = function() end }
local W, H = canvas.canvas_w, canvas.canvas_h
print("screen:", W, H)

-- 构造:每层 30 条自由笔画(各 60 点折线)+ 2 个大填充 + 3 个图形 + 1 文字
local function buildLayer(li, seed)
    canvas:_switchLayer(li)
    for s = 1, 30 do
        local pts = {}
        for i = 0, 59 do
            pts[#pts + 1] = {
                x = 20 + ((s * 37 + i * 13 + seed * 7) % (W - 60)),
                y = 20 + ((s * 53 + i * 29 + seed * 11) % (H - 160)),
            }
        end
        local el = { kind = "freehand", points = pts, gray = 1.0, width = 4, tip = "circle" }
        table.insert(canvas.elements, el)
        canvas:_cacheBBox(el)
    end
    for f = 1, 2 do
        local pts = {}
        for i = 0, 7 do
            local ang = i * math.pi / 4
            pts[#pts + 1] = { x = 100 + f * 200 + math.cos(ang) * 90, y = 200 + f * 150 + math.sin(ang) * 80 }
        end
        local smooth = canvas:_smoothClosedPath(pts)
        local el = { kind = "fill", spans = canvas:_polygonFillSpans(smooth), gray = 0.5 }
        table.insert(canvas.elements, el)
        canvas:_cacheBBox(el)
    end
    for g = 1, 3 do
        local el = { kind = "circle", cx = 80 + g * 120, cy = 120 + g * 40, rx = 50, ry = 40,
            gray = 0.8, width = 5, rot = g * 0.3 }
        table.insert(canvas.elements, el)
        canvas:_cacheBBox(el)
    end
    local tel = { kind = "text", x = 40, y = 60 + seed * 30, text = "测试文字 ABCD 123",
        font = canvas.font, size = 24, gray = 1.0 }
    table.insert(canvas.elements, tel)
    canvas:_cacheBBox(tel)
end

local function timeit(name, fn, n)
    local t0 = os.clock()
    for _ = 1, (n or 1) do fn() end
    print(string.format("%s: %.1f ms", name, (os.clock() - t0) * 1000 / (n or 1)))
end

for li = 1, 3 do buildLayer(li, li) end
print("elements per layer:", #canvas.layers[1], #canvas.layers[2], #canvas.layers[3])

timeit("_renderAll (full replay)", function() canvas:_renderAll() end, 3)
timeit("drawAllLayers only", function()
    canvas.canvas_bb:paintRect(0, 0, W, H, Blitbuffer.COLOR_WHITE)
    canvas:_drawAllLayers()
end, 3)

-- 分解:每层重放耗时
for li = 1, 3 do
    timeit("replay layer " .. li, function()
        for _, el in ipairs(canvas.layers[li]) do
            if el.kind == "text" then
                canvas:_drawTextTo(canvas.canvas_bb, el)
            else
                shapes.drawElement(canvas.canvas_bb, el, Blitbuffer.gray(el.gray))
            end
        end
    end, 3)
end

-- blit 一次全屏的成本(对比)
local src = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
timeit("full-screen blitFrom", function()
    canvas.canvas_bb:blitFrom(src, 0, 0, 0, 0, W, H)
end, 10)

-- 显隐切换总耗时(含 setDirty)
timeit("_toggleLayerVisible", function() canvas:_toggleLayerVisible() end, 3)
canvas:onCloseWidget()
