--[[--
透明度(alpha)功能单测:
1. shapes.alphaProxy:白底上混合 ≈α·墨色+(1-α)·底,叠在墨迹上透出下层;越界裁剪安全
2. drawElement 带 alpha(fill 元素全路径)
3. 画布集成:半透明实心矩形提交 + 区域重绘(负偏移)前后逐像素一致
4. 图层系数与元素 alpha 相乘
5. _resolveAlpha 随机取值范围与分级多样性
6. _applySelectedAlpha 应用 + 撤销恢复(像素级)
7. 半透明文字走临时 BB 混合路径:无全黑像素,不透明对照有
8. 属性面板 alpha_btn(与笔触并排)/ 图层面板 layer_alpha_btn 存在

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/alpha_test.lua
--]]

-- 自定位插件根注入 package.path(与 feature_test 同款)
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")

-- 前置初始化必须早于任何 require("ui/uimanager")/require("device")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local Blitbuffer = require("ffi/blitbuffer")
local shapes = require("drawingpad.shapes")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local function newCanvas()
    return DrawingCanvas:new{ on_close = function() end }
end

local function px(bb, x, y)
    -- 屏幕帧缓冲可能是 ColorRGB32(模拟器)无 .a 字段:灰度内容 r≈g≈b,取 r 当灰度
    local p = bb:getPixel(x, y)
    if not p then
        return -1
    end
    local ok, v = pcall(function() return p.a end)
    if ok and v then
        return v
    end
    local ok2, r = pcall(function() return p.r end)
    if ok2 and r then
        return r
    end
    return -1
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

-- 1. alphaProxy 基本混合
section("proxy blend on white / over ink / clipping", function()
    local bb = Blitbuffer.new(20, 20, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, 20, 20, Blitbuffer.COLOR_WHITE)
    local proxy = shapes.alphaProxy(bb, 0.5)
    -- 黑 50% 画白底上半区 → ≈128
    proxy:paintRect(0, 0, 20, 10, Blitbuffer.gray(1.0))
    local v = px(bb, 10, 5)
    check(math.abs(v - 128) <= 2, "black 50% over white ~= 128, got " .. v)
    -- 下半区先铺黑墨,再 50% 黑盖上去 → 透出下层,仍黑
    bb:paintRect(0, 10, 20, 10, Blitbuffer.gray(1.0))
    proxy:paintRect(0, 10, 20, 10, Blitbuffer.gray(1.0))
    check(px(bb, 10, 15) <= 4, "50% over black ink stays black, got " .. px(bb, 10, 15))
    -- 越界区域安全(native paintRect 裁剪):新画布上画越界矩形,只有画布内部分被混合
    local bb2 = Blitbuffer.new(10, 10, Blitbuffer.TYPE_BB8)
    bb2:paintRect(0, 0, 10, 10, Blitbuffer.COLOR_WHITE)
    local p2 = shapes.alphaProxy(bb2, 0.5)
    p2:paintRect(-5, -5, 10, 10, Blitbuffer.gray(1.0)) -- 裁剪后只写 (0..4, 0..4)
    local cv = px(bb2, 0, 0)
    check(math.abs(cv - 128) <= 2, "clipped paint blends at top-left, got " .. cv)
    check(px(bb2, 8, 8) >= 253, "clipped paint left outside untouched, got " .. px(bb2, 8, 8))
    bb2:free()
    bb:free()
end)

-- 2. drawElement 带 alpha(fill 元素全路径)
section("drawElement fill with alpha", function()
    local bb = Blitbuffer.new(60, 60, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, 60, 60, Blitbuffer.COLOR_WHITE)
    -- 先铺一条黑竖条 x=0..9
    bb:paintRect(0, 0, 10, 60, Blitbuffer.gray(1.0))
    -- 全幅半透明黑 fill 元素走代理渲染
    local el = { kind = "fill", spans = {}, gray = 1.0, alpha = 0.5 }
    for y = 0, 59 do
        el.spans[#el.spans + 1] = { y, 0, 59 }
    end
    shapes.drawElement(shapes.alphaProxy(bb, el.alpha), el, Blitbuffer.gray(el.gray))
    check(px(bb, 5, 30) <= 4, "alpha fill over ink keeps ink, got " .. px(bb, 5, 30))
    local v = px(bb, 30, 30)
    check(math.abs(v - 128) <= 2, "alpha fill over white ~= 128, got " .. v)
    bb:free()
end)

-- 3. 画布集成:半透明实心矩形 + 区域重绘一致性
section("canvas alpha rect + region redraw identity", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    canvas.alpha = 0.5
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 380 } })
    check(#canvas.elements == 1, "alpha rect committed, got " .. #canvas.elements)
    local el = canvas.elements[1]
    check(el.alpha == 0.5, "element alpha recorded, got " .. tostring(el.alpha))
    local v = px(canvas.canvas_bb, 150, 340)
    check(math.abs(v - 128) <= 3, "alpha rect center ~= 128, got " .. v)
    -- 区域重绘(随机小区域)前后逐像素一致
    local before = px(canvas.canvas_bb, 150, 340)
    canvas:_redrawRegion({ x = 90, y = 290, w = 60, h = 40 })
    check(px(canvas.canvas_bb, 150, 340) == before,
        "region redraw pixel identical, before " .. before .. " after " .. px(canvas.canvas_bb, 150, 340))
    canvas:onCloseWidget()
end)

-- 4. 图层系数 × 元素 alpha
section("layer alpha multiply", function()
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.alpha = 1.0
    canvas.layer_alpha[2] = 0.5 -- 当前层(中层)整体 50%
    canvas:onTap(nil, { pos = { x = 150, y = 400 } })
    local el = canvas.elements[1]
    check(el.alpha == 1.0, "element alpha untouched")
    local v = px(canvas.canvas_bb, 150, 400)
    check(math.abs(v - 128) <= 3, "layer 0.5 × element 1.0 ~= 128, got " .. v)
    canvas:onCloseWidget()
end)

-- 5. _resolveAlpha 随机
section("resolve alpha random", function()
    local canvas = newCanvas()
    canvas.alpha_random = true
    canvas.alpha_min = 0.2
    canvas.alpha_max = 0.8
    canvas.alpha_levels = 5
    for _ = 1, 30 do
        local a = canvas:_resolveAlpha()
        check(a >= 0.2 - 1e-9 and a <= 0.8 + 1e-9, "random alpha in [min,max], got " .. a)
    end
    local seen = {}
    for _ = 1, 300 do
        seen[string.format("%.3f", canvas:_resolveAlpha())] = true
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    check(n >= 2, "random alpha takes multiple levels, got " .. n)
    canvas.alpha_random = false
    check(canvas:_resolveAlpha() == canvas.alpha, "fixed mode returns current")
    canvas:onCloseWidget()
end)

-- 6. 选中对象透明度 + 撤销恢复(像素级)
section("apply selected alpha + undo", function()
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas:onTap(nil, { pos = { x = 150, y = 300 } })
    local el = canvas.elements[1]
    canvas:_setTool("select")
    canvas:onTap(nil, { pos = { x = 150, y = 300 } })
    check(canvas._selected == el, "element selected")
    canvas:_applySelectedAlpha(50)
    check(math.abs(el.alpha - 0.5) < 0.001, "alpha applied, got " .. tostring(el.alpha))
    local v = px(canvas.canvas_bb, 150, 300)
    check(math.abs(v - 128) <= 3, "pixel ~= 128 after apply, got " .. v)
    check(#canvas.undo >= 1, "undo recorded")
    canvas:_undo()
    check(math.abs(el.alpha - 1.0) < 0.001, "undo restores alpha")
    v = px(canvas.canvas_bb, 150, 300)
    check(v <= 4, "undo restores original opaque black dot, got " .. v)
    canvas:onCloseWidget()
end)

-- 7. 半透明文字
section("text alpha path", function()
    local canvas = newCanvas()
    local el = {
        kind = "text", x = 100, y = 300, text = "测试A",
        font = canvas.font, size = 40, gray = 1.0, alpha = 0.5,
    }
    canvas:_cacheBBox(el)
    check(el._bbox ~= nil, "text bbox computed")
    canvas:_drawTextTo(canvas.canvas_bb, el)
    local b = el._bbox
    local minv = 255
    for yy = math.floor(b.y0), math.ceil(b.y1) do
        for xx = math.floor(b.x0), math.ceil(b.x1) do
            local v = px(canvas.canvas_bb, xx, yy)
            if v >= 0 and v < minv then minv = v end
        end
    end
    check(minv > 60, "alpha text has no full-black pixel, min=" .. minv)
    -- 不透明对照:同位置再画应出现接近全黑的像素(覆盖验证混合路径生效)
    local el2 = {
        kind = "text", x = 100, y = 300, text = "测试A",
        font = canvas.font, size = 40, gray = 1.0,
    }
    canvas:_drawTextTo(canvas.canvas_bb, el2)
    local minv2 = 255
    for yy = math.floor(b.y0), math.ceil(b.y1) do
        for xx = math.floor(b.x0), math.ceil(b.x1) do
            local v = px(canvas.canvas_bb, xx, yy)
            if v >= 0 and v < minv2 then minv2 = v end
        end
    end
    check(minv2 <= 60, "opaque text has near-black pixel, min=" .. minv2)
    canvas:onCloseWidget()
end)

-- 8. 面板条目存在(与笔触并排)
section("panel entries", function()
    local canvas = newCanvas()
    local bt = canvas:_categoryBt("prop")
    check(bt.button_by_id["alpha_btn"] ~= nil, "alpha_btn in prop panel")
    check(bt.button_by_id["tip_btn"] ~= nil, "tip_btn still present")
    check(bt.button_by_id["gray_btn"] ~= nil and bt.button_by_id["width_btn"] ~= nil,
        "gray/width buttons intact")
    local lbt = canvas:_categoryBt("layer")
    check(lbt.button_by_id["layer_alpha_btn"] ~= nil, "layer_alpha_btn in layer panel")
    canvas:onCloseWidget()
end)

-- 9. 半透明文字拖拽预览画到屏幕 BB(回归:模拟器屏幕帧缓冲是 ColorRGB32,
-- 旧实现 getPixel().a 直接崩——修复后走原生 setPixelBlend,任意 BB 类型正确)
section("text alpha drag preview on screen bb", function()
    local canvas = newCanvas()
    local el = {
        kind = "text", x = 100, y = 200, text = "测",
        font = canvas.font, size = 30, gray = 1.0, alpha = 0.5,
    }
    canvas:_cacheBBox(el)
    canvas:_setTool("select")
    canvas._selected = el
    canvas._drag_preview = {
        kind = "text", x = 130, y = 230, text = "测",
        font = canvas.font, size = 30, gray = 1.0, alpha = 0.5,
    }
    local Screen = require("device").screen
    local ok, err = pcall(function() canvas:paintTo(Screen.bb, 0, 0) end)
    check(ok, "paintTo with alpha text preview on screen bb: " .. tostring(err))
    -- 预览位置应有墨迹(混合生效,不是画了空气)
    local b = el._bbox
    local ink = 0
    for yy = math.floor(b.y0), math.ceil(b.y1) + 60 do
        for xx = math.floor(b.x0), math.ceil(b.x1) + 60 do
            local v = px(Screen.bb, xx, yy)
            if v >= 0 and v < 200 then
                ink = ink + 1
            end
        end
    end
    check(ink > 10, "alpha text preview left ink on screen bb, ink=" .. ink)
    canvas:onCloseWidget()
end)

print(string.format("RESULT: all %d sections passed", passed))
