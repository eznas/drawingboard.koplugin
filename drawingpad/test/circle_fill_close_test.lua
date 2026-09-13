--[[--
回归:实心圆形拉伸后旋转保持实心 + 关闭画板时分类菜单不残留
1. 实心圆 → 非等比拉伸成椭圆 → 旋转:渲染中心与内部仍是墨(filled 丢失=中心白)
2. onCloseWidget 关闭仍打开的分类面板(退出按钮/Back 键等所有 close 路径共用)

运行(从 KOReader 模拟器根目录):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/circle_fill_close_test.lua
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

local PASS, FAIL = 0, 0
local function check(cond, msg)
    if cond then
        PASS = PASS + 1
        print("PASS " .. msg)
    else
        FAIL = FAIL + 1
        print("FAIL " .. msg)
    end
end

local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

-- ============ 1. 实心圆拉伸→旋转保持实心 ============
do
    local function renderEl(el)
        local bb = Blitbuffer.new(400, 400, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        shapes.drawElement(bb, el, Blitbuffer.gray(1), 0, 0)
        return bb
    end

    local el = { kind = "circle", cx = 200, cy = 200, r = 80, rx = 80, ry = 80,
        width = 3, filled = true }

    -- 基线:实心圆渲染中心有墨
    local bb = renderEl(el)
    check(bb:getPixel(200, 200).a < 128, "solid circle renders ink at center")
    bb:free()

    -- 拉伸(非等比 1.5x/1x → 椭圆)
    local c = newCanvas()
    local sb = { x0 = 120, y0 = 120, x1 = 280, y1 = 280 }
    local nb = { x0 = 120, y0 = 120, x1 = 360, y1 = 280 }
    c:_scaleElement(el, sb, nb)
    c:_cacheBBox(el)
    check(el.filled == true, "scale keeps filled")
    check(el.rx == 120 and el.ry == 80, "scale makes ellipse, got rx="
        .. tostring(el.rx) .. " ry=" .. tostring(el.ry))

    -- 旋转 30°:修复前渲染退化描边(中心白),修复后中心有墨
    c:_rotateElement(el, math.pi / 6, el.cx, el.cy)
    c:_cacheBBox(el)
    check(el.filled == true and (el.rot or 0) ~= 0, "rotate keeps filled and sets rot")
    bb = renderEl(el)
    check(bb:getPixel(200, 200).a < 128, "rotated solid ellipse has ink at center (was hollow)")
    -- 椭圆长轴端内一点(旋转 30° 后长轴端 (311,230) 方向)也应有墨
    local lx = 200 + 110 * math.cos(math.pi / 6)
    local ly = 200 + 110 * math.sin(math.pi / 6)
    check(bb:getPixel(math.floor(lx), math.floor(ly)).a < 128,
        "rotated solid ellipse has ink near major axis tip")
    bb:free()

    -- 再转 90° 仍实心
    c:_rotateElement(el, math.pi / 2, el.cx, el.cy)
    bb = renderEl(el)
    check(bb:getPixel(200, 200).a < 128, "rotated 90+30 deg still solid")
    bb:free()
end

-- ============ 2. 关闭画板时分类菜单不残留 ============
do
    local UIManager = require("ui/uimanager")
    local shown, closed = {}, {}
    local orig_show, orig_close = UIManager.show, UIManager.close
    UIManager.show = function(self_w, w) shown[#shown + 1] = w end
    UIManager.close = function(self_w, w, ...) closed[#closed + 1] = w end

    local c = newCanvas()
    c:_showCategoryMenu("func")
    local popup = c._category_popup
    check(popup ~= nil and c._open_cat == "func", "func panel opens")

    c:onCloseWidget() -- 退出按钮/Back 键关闭画板的公共析构路径
    check(closed[#closed] == popup and c._category_popup == nil and c._open_cat == nil,
        "onCloseWidget closes category popup (no residue)")

    UIManager.show, UIManager.close = orig_show, orig_close
end

-- ============ 7. 实心矩形旋转后保持实心(v61k:poly 渲染补填充) ============
do
    local el = { kind = "rect", x0 = 150, y0 = 250, x1 = 250, y1 = 350,
        width = 3, filled = true }
    local c = newCanvas()
    c:_rotateElement(el, math.pi / 4, 200, 300) -- 旋转后 rect → poly
    c:_cacheBBox(el)
    check(el.kind == "poly" and el.filled == true, "rotated rect stays filled poly")
    local bb = Blitbuffer.new(400, 600, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    shapes.drawElement(bb, el, Blitbuffer.gray(1), 0, 0)
    check(bb:getPixel(200, 300).a < 128, "rotated solid rect has ink at center (was hollow)")
    -- 实心内部可选中(_inkDistance 命中)
    check(c:_inkDistance(el, 200, 300) == 0, "inkDistance 0 inside filled poly (selectable)")
    bb:free()
end

print(string.format("=== circle_fill_close_test: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
