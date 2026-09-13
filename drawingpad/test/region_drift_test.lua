--[[--
马赛克定位:多笔半透明/不透明笔迹连续绘制(实时 flush + 收笔),
每次提交后把画布与"全新整幅重放"的结果逐像素对比,差异即区域重放漂移(矩形马赛克)。
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

local W, H = 800, 600
local canvas = DrawingCanvas:new{ on_close = function() end }
canvas.canvas_w, canvas.canvas_h = W, H
canvas.canvas_bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
canvas.canvas_bb:fill(Blitbuffer.COLOR_WHITE)
canvas.layers = { {}, {}, {} }
canvas.elements = canvas.layers[2]
canvas.active_layer = 2
canvas.layer_visible = { true, true, true }
canvas.layer_alpha = { 1, 1, 0.25 } -- 与真机一致:上层 25%
canvas:_renderAll()

local function snapshot()
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    bb:blitFrom(canvas.canvas_bb, 0, 0, 0, 0, W, H)
    return bb
end
local function fullReplay()
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    for li = 1, 3 do
        if canvas.layer_visible[li] then
            for _, el in ipairs(canvas.layers[li]) do
                local ok = pcall(function()
                    if el.kind == "text" then
                        local t = {}
                        for k, v in pairs(el) do t[k] = v end
                        canvas:_drawTextTo(bb, t, li)
                    else
                        shapes.drawElement(canvas:_alphaBB(bb, el, li), el, Blitbuffer.gray(el.gray))
                    end
                end)
                if not ok then print('ERR replay', el.kind) end
            end
        end
    end
    return bb
end
local function diffRects(a, b)
    local n = 0
    local minx, miny, maxx, maxy = math.huge, math.huge, -1, -1
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            if a:getPixel(x, y).a ~= b:getPixel(x, y).a then
                n = n + 1
                if x < minx then minx = x end
                if x > maxx then maxx = x end
                if y < miny then miny = y end
                if y > maxy then maxy = y end
            end
        end
    end
    return n, minx, miny, maxx, maxy
end

-- 模拟一笔:实时 flush 若干次 + 收笔(与 gestures 流程同路径)
local function drawStroke(points, attrs, flush_every)
    canvas.tool = attrs.tool or "brush"
    local s = {
        kind = "freehand", points = {}, width = attrs.width,
        gray = attrs.gray, alpha = attrs.alpha, tip = attrs.tip or "circle",
    }
    canvas._stroke = s
    local nflush = 0
    for i, p in ipairs(points) do
        table.insert(s.points, p)
        canvas:_renderStrokeTail()
        canvas._stroke_region = canvas:_mergeRegions(canvas._stroke_region,
            canvas:_dirtyRegion(p.x, p.y, p.x, p.y, s.width + 2))
        if i % flush_every == 0 then
            canvas:_flushStrokeRepaint()
            nflush = nflush + 1
        end
    end
    canvas:_finishStroke(points[#points].x, points[#points].y)
    -- 每笔提交后:画布 vs 整幅重放
    local snap = snapshot()
    local ref = fullReplay()
    local n, x0, y0, x1, y1 = diffRects(snap, ref)
    print(string.format('stroke #%d (alpha=%s w=%d gray=%s flushes=%d): diff=%d bbox=(%d,%d)-(%d,%d)',
        canvas.elements and #canvas.elements or 0, tostring(attrs.alpha), attrs.width,
        tostring(attrs.gray), nflush, n, x0, y0, x1, y1))
    if n > 0 then
        local vis = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
        vis:fill(Blitbuffer.COLOR_WHITE)
        for y = 0, H - 1 do
            for x = 0, W - 1 do
                if snap:getPixel(x, y).a ~= ref:getPixel(x, y).a then
                    vis:setPixel(x, y, Blitbuffer.Color8(0))
                end
            end
        end
        vis:writePNG('/tmp/diff_stroke' .. #canvas.elements .. '.png')
        snap:writePNG('/tmp/snap_stroke' .. #canvas.elements .. '.png')
        ref:writePNG('/tmp/ref_stroke' .. #canvas.elements .. '.png')
        vis:free()
    end
    snap:free()
    ref:free()
end

local function hline(y, x0, x1, step)
    local pts = {}
    for x = x0, x1, step do pts[#pts + 1] = { x = x, y = y } end
    return pts
end

-- 真机同款参数:宽 21-100 随机、灰度随机、alpha、上层 layer_alpha 0.25
drawStroke(hline(150, 60, 700, 12), { width = 60, gray = 0.75, alpha = 0.5 }, 4)
drawStroke(hline(300, 700, 80, -12), { width = 100, gray = 0.3, alpha = 1 }, 5)
drawStroke(hline(220, 100, 650, 9), { width = 24, gray = 0.5, alpha = 0.35 }, 3)
drawStroke(hline(420, 650, 120, -11), { width = 90, gray = 0.9, alpha = 0.8 }, 6)
-- 交叉:半透明穿过不透明
drawStroke(hline(260, 80, 720, 10), { width = 40, gray = 1, alpha = 0.6 }, 4)

print('DONE')
os.exit(0)
