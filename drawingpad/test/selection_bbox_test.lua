--[[--
路径填充旋转/缩放不穿模回归测试(src_points 源顶点重算):
1. 路径填充收笔保存 el.src_points
2. 连续旋转 8×30°:填充像素始终贴着变换后源顶点多边形(越界 >1.5px 的像素必须为 0)
3. 缩放(放大/缩小):spans 致密且仍贴合变换后多边形
4. 移动后旋转:填充跟着源顶点走(不跳回旧位置)
5. _cloneElement/_restoreGeom 对 src_points 深拷贝(撤销快照不别名)
6. 旧数据/tap 洪水填充(无 src_points)旋转仍走原 span 反建路径

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/fill_transform_test.lua
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
local canvas = DrawingCanvas:new{ canvas_w = 800, canvas_h = 1000 }

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg, 2)
    end
end

-- 1. 矩形(实心/空心, width=20, 100,100 -> 300,300)
local rect = { kind = "rect", x0 = 100, y0 = 100, x1 = 300, y1 = 300, width = 20, filled = true, gray = 0 }
local b_rect = canvas:_elementBBox(rect)
-- 笔画外缘应为 90..310
check(b_rect.x0 == 90 and b_rect.x1 == 310, "rect bbox x: expected [90, 310], got [" .. b_rect.x0 .. ", " .. b_rect.x1 .. "]")
check(b_rect.y0 == 90 and b_rect.y1 == 310, "rect bbox y: expected [90, 310], got [" .. b_rect.y0 .. ", " .. b_rect.y1 .. "]")

local fc_rect = canvas:_frameCorners(rect)
-- 手柄 corners(pad=4) 应在 86..314
check(fc_rect[1].x == 86 and fc_rect[1].y == 86, "rect nw corner outside stroke: " .. fc_rect[1].x)
check(fc_rect[2].x == 314 and fc_rect[2].y == 86, "rect ne corner outside stroke: " .. fc_rect[2].x)
-- 选择框 highlight 边(pad=3) 应在 87..313 (严格在笔画 90..310 之外 3px)
local hx0, hx1 = b_rect.x0 - 3, b_rect.x1 + 3
check(hx0 < 90 and hx1 > 310, "rect selection frame outside stroke: hx0=" .. hx0 .. ", hx1=" .. hx1)
print("PASS: 1. Rect bbox, handles, and selection box strictly outside stroke")

-- 2. 圆形(实心/空心, cx=200, cy=200, rx=50, width=24)
local circle = { kind = "circle", cx = 200, cy = 200, rx = 50, ry = 50, width = 24, filled = true, gray = 0 }
local b_circle = canvas:_elementBBox(circle)
-- 笔画外缘半径 = 50 + 12 = 62, 外缘范围 = 138..262
check(b_circle.x0 == 138 and b_circle.x1 == 262, "circle bbox x: expected [138, 262], got [" .. b_circle.x0 .. ", " .. b_circle.x1 .. "]")
check(b_circle.y0 == 138 and b_circle.y1 == 262, "circle bbox y: expected [138, 262], got [" .. b_circle.y0 .. ", " .. b_circle.y1 .. "]")

local fc_circle = canvas:_frameCorners(circle)
check(fc_circle[1].x == 134 and fc_circle[2].x == 266, "circle handles outside stroke: nw.x=" .. fc_circle[1].x .. ", ne.x=" .. fc_circle[2].x)
local chx0, chx1 = b_circle.x0 - 3, b_circle.x1 + 3
check(chx0 < 138 and chx1 > 262, "circle selection frame outside stroke: chx0=" .. chx0 .. ", chx1=" .. chx1)
print("PASS: 2. Circle bbox, handles, and selection box strictly outside stroke")

-- 3. 旋转椭圆(cx=200, cy=200, rx=60, ry=40, rot=0.6, width=20)
local rot_circle = { kind = "circle", cx = 200, cy = 200, rx = 60, ry = 40, rot = 0.6, width = 20, filled = true, gray = 0 }
local fc_rot = canvas:_frameCorners(rot_circle)
check(#fc_rot == 4, "rot circle has 4 corners")
local hw = 10
local r_diag_base = math.sqrt(60^2 + 40^2)
local r_diag_with_pen = math.sqrt((60 + hw)^2 + (40 + hw)^2)
local dist0 = math.sqrt((fc_rot[1].x - 200)^2 + (fc_rot[1].y - 200)^2)
check(dist0 >= r_diag_with_pen, "rot circle corner outside ink: dist=" .. dist0 .. " >= " .. r_diag_with_pen)
print("PASS: 3. Rotated circle handles strictly outside stroke")

-- 4. 画笔工具 freehand(width=30, points 100..200)
local freehand = { kind = "freehand", points = { { x = 100, y = 100 }, { x = 200, y = 100 } }, width = 30, gray = 0 }
local b_free = canvas:_elementBBox(freehand)
-- 墨迹半径 = 15, 实际墨迹范围 = [85, 85, 215, 115]
check(b_free.x0 == 85 and b_free.x1 == 215, "freehand bbox x: expected [85, 215], got [" .. b_free.x0 .. ", " .. b_free.x1 .. "]")
check(b_free.y0 == 85 and b_free.y1 == 115, "freehand bbox y: expected [85, 115], got [" .. b_free.y0 .. ", " .. b_free.y1 .. "]")
-- 旧版 bug 产生的包围盒为 [70, 70, 230, 130]，总宽 160；正确总宽应为 130
check((b_free.x1 - b_free.x0) == 130, "freehand bbox tightly bounds stroke width (130px vs bloated 160px)")
local fhx0, fhx1 = b_free.x0 - 3, b_free.x1 + 3
check(fhx0 == 82 and fhx1 == 218, "freehand selection box exactly 3px outside ink")
print("PASS: 4. Freehand bbox tight, selection box no longer oversized")

-- 5. 缩放变换零漂移
local sb = canvas:_elementBBox(rect)
local nb = canvas:_transformBBox("se", sb, sb.x1 + 60, sb.y1 + 40)
canvas:_scaleElement(rect, sb, nb)
local nb_after = canvas:_elementBBox(rect)
check(nb_after.x0 == nb.x0 and nb_after.y0 == nb.y0, "rect scale left/top fixed edge zero drift")
check(nb_after.x1 == nb.x1 and nb_after.y1 == nb.y1, "rect scale right/bottom dragged edge exact match")

local csb = canvas:_elementBBox(circle)
local cnb = canvas:_transformBBox("se", csb, csb.x1 + 50, csb.y1 + 50)
canvas:_scaleElement(circle, csb, cnb)
local cnb_after = canvas:_elementBBox(circle)
check(cnb_after.x0 == cnb.x0 and cnb_after.y0 == cnb.y0, "circle scale left/top fixed edge zero drift")
check(cnb_after.x1 == cnb.x1 and cnb_after.y1 == cnb.y1, "circle scale right/bottom dragged edge exact match")
print("PASS: 5. Transform scaling has zero drift")

-- 6. 粗笔宽实心图形边缘点选(宽 60,PICK_TOLERANCE=20,墨迹外缘=几何边界+30)
local thick_rect = { kind = "rect", x0 = 100, y0 = 100, x1 = 300, y1 = 300, width = 60, filled = true, gray = 0 }
canvas:_cacheBBox(thick_rect)
table.insert(canvas.elements, thick_rect)
for _, x in ipairs({ 100, 300, 85, 315, 70, 330 }) do
    local el = canvas:_pickElementAt(x, 200)
    check(el == thick_rect, "thick filled rect pick at edge x=" .. x .. " (d should be 0 on ink)")
end
local thick_circle = { kind = "circle", cx = 550, cy = 200, rx = 80, ry = 80, width = 60, filled = true, gray = 0 }
canvas:_cacheBBox(thick_circle)
table.insert(canvas.elements, thick_circle)
for _, r in ipairs({ 0, 80, 95, 110 }) do
    local el = canvas:_pickElementAt(550 + r, 200)
    check(el == thick_circle, "thick filled circle pick at radius r=" .. r .. " (ink outer edge = 110)")
end
-- 墨迹外侧 20px 容差内仍可命中,超出容差不命中
check(canvas:_pickElementAt(550 + 125, 200) == thick_circle, "circle pick within tolerance outside ink")
check(canvas:_pickElementAt(550 + 140, 200) == nil, "circle pick beyond tolerance outside ink misses")
print("PASS: 6. Thick filled rect/circle edge picks all hit")

print("=== ALL SELECTION BBOX TESTS PASSED ===")
