--[[--
绘图板 headless 渲染自测:
画直线/矩形/圆/圆弧/粗笔折线/橡皮擦除 → writePNG → 校验 PNG magic;
再尝试构造 DrawingCanvas widget 并打印布局尺寸(工具栏高度等,供核对)。

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/render_test.lua
--]]

-- 绘图板模块已随插件移入 plugins/drawingboard.koplugin/drawingpad/:
-- 测试不经 pluginloader,自定位插件根注入 package.path,使 require("drawingpad.*") 可解析
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")

local Blitbuffer = require("ffi/blitbuffer")
local shapes = require("drawingpad.shapes")

local W, H = 320, 240
local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
bb:paintRect(0, 0, W, H, Blitbuffer.COLOR_WHITE)

local black = Blitbuffer.gray(1.0)
local gray = Blitbuffer.gray(0.5)

-- 画笔折线(粗 8)
shapes.polyline(bb, { { x = 10, y = 20 }, { x = 60, y = 80 }, { x = 120, y = 40 }, { x = 180, y = 90 } }, 8, black)
-- 直线(粗 4)
shapes.thickLine(bb, 10, 110, 300, 110, 4, gray)
-- 矩形(粗 6)
shapes.rect(bb, 20, 130, 140, 220, 6, black)
-- 圆形(粗 4)
shapes.circle(bb, 220, 170, 45, 4, gray)
-- 橡皮(白,粗 12):在折线上擦一段
shapes.polyline(bb, { { x = 40, y = 45 }, { x = 70, y = 60 }, { x = 100, y = 50 } }, 12, Blitbuffer.COLOR_WHITE)
-- 越界安全:完全在画布外的点不应报错
shapes.thickLine(bb, -50, -50, -10, -10, 4, black)

local out = "/tmp/drawingpad_test.png"
bb:writePNG(out)

local f = io.open(out, "rb")
if not f then
    print("FAIL: cannot open output", out)
    os.exit(1)
end
local magic = f:read(8)
f:close()
local expected = string.char(137, 80, 78, 71, 13, 10, 26, 10)
if magic ~= expected then
    print("FAIL: bad PNG magic:", magic and #magic or "nil")
    os.exit(1)
end
print("PASS: shapes rendered, PNG magic OK ->", out)

-- 圆完整性:画完整圆,检查上/下/左/右四点极值在描边上
local ok_circ, err_circ = pcall(function()
    local bbc = Blitbuffer.new(200, 200, Blitbuffer.TYPE_BB8)
    bbc:paintRect(0, 0, 200, 200, Blitbuffer.COLOR_WHITE)
    shapes.circle(bbc, 100, 100, 60, 8, Blitbuffer.gray(1.0))
    local function grayAt(x, y)
        local p = bbc:getPixel(x, y)
        return p and p.a
    end
    if grayAt(100, 40) ~= 0 then error("circle top missing") end
    if grayAt(100, 160) ~= 0 then error("circle bottom missing") end
    if grayAt(40, 100) ~= 0 then error("circle left missing") end
    if grayAt(160, 100) ~= 0 then error("circle right missing") end
    print("circle extremes black: top/bottom/left/right OK")
end)
if ok_circ then
    print("PASS: full circle rendering OK")
else
    print("FAIL: full circle:", tostring(err_circ))
    os.exit(1)
end

-- 实心图形 + 矩形框橡皮:像素级验证
local ok_fill, err_fill = pcall(function()
    local bbf = Blitbuffer.new(100, 100, Blitbuffer.TYPE_BB8)
    bbf:paintRect(0, 0, 100, 100, Blitbuffer.COLOR_WHITE)
    local black = Blitbuffer.gray(1.0)
    -- 实心矩形 / 实心圆(填充 + 描边)
    shapes.drawElement(bbf, { kind = "rect", x0 = 10, y0 = 10, x1 = 60, y1 = 60, filled = true, width = 4 }, black)
    shapes.drawElement(bbf, { kind = "circle", cx = 80, cy = 30, r = 15, filled = true, width = 2 }, black)
    -- 空心矩形:中心应为白(255)
    shapes.drawElement(bbf, { kind = "rect", x0 = 70, y0 = 60, x1 = 95, y1 = 90, filled = false, width = 2 }, black)
    local function grayAt(x, y)
        local px = bbf:getPixel(x, y)
        return px and px.a
    end
    local c_rect = grayAt(35, 35)  -- 实心矩形中心 → 黑(0)
    local c_circ = grayAt(80, 30)  -- 实心圆圆心 → 黑(0)
    local c_hollow = grayAt(82, 75) -- 空心矩形中心 → 白(255)
    if c_rect ~= 0 then error("filled rect center not black: " .. tostring(c_rect)) end
    if c_circ ~= 0 then error("filled circle center not black: " .. tostring(c_circ)) end
    if c_hollow ~= 255 then error("hollow rect center not white: " .. tostring(c_hollow)) end
    print("pixels: filled rect/circle centers =", c_rect, c_circ, ", hollow rect center =", c_hollow)
    -- 矩形框橡皮:白色实心矩形擦除
    shapes.drawElement(bbf, { kind = "rect", x0 = 20, y0 = 20, x1 = 50, y1 = 50, filled = true, gray = 0, width = 2 }, Blitbuffer.COLOR_WHITE)
    local c_eras = grayAt(35, 35)
    if c_eras ~= 255 then error("rect eraser center not white: " .. tostring(c_eras)) end
    print("rect eraser center =", c_eras)
end)
if ok_fill then
    print("PASS: filled shapes + rect eraser pixels OK")
else
    print("FAIL: filled shapes:", tostring(err_fill))
    os.exit(1)
end

-- 尝试构造 DrawingCanvas,打印布局尺寸供核对
-- (构造 widget 需要与 tools/wbuilder.lua 相同的前置初始化)
local ok_canvas, err = pcall(function()
    G_defaults = require("luadefaults"):open()
    local DataStorage = require("datastorage")
    G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
    local Device = require("device")
    local CanvasContext = require("document/canvascontext")
    CanvasContext:init(Device)
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    local canvas = DrawingCanvas:new{ on_close = function() end }
    print(string.format("canvas: %dx%d, toolbar_h=%d, status_h=%d, header_h=%d, canvas_bb=%dx%d",
        canvas.dimen.w, canvas.dimen.h,
        canvas.toolbar_h, canvas.status_h, canvas.header_h,
        canvas.canvas_w, canvas.canvas_h))
    canvas.canvas_bb:free()
end)
if ok_canvas then
    print("PASS: DrawingCanvas construct OK")
    -- 文字渲染(默认字体来自 fonts 目录,失败只告警)
    local ok_text, err_text = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        print("default font:", canvas.font)
        canvas:_drawTextTo(canvas.canvas_bb, {
            kind = "text", x = 10, y = 30,
            text = "绘图板 DrawingPad 123",
            font = canvas.font, size = 24, gray = 1.0,
        })
        local out2 = "/tmp/drawingpad_text_test.png"
        canvas.canvas_bb:writePNG(out2)
        local f2 = io.open(out2, "rb")
        local magic2 = f2 and f2:read(8)
        if f2 then f2:close() end
        if magic2 == expected then
            print("PASS: text render + PNG OK ->", out2)
        else
            print("WARN: text PNG magic mismatch:", magic2 and #magic2 or "nil")
        end
    end)
    if not ok_text then
        print("WARN: text render failed (GUI 环境再验):", tostring(err_text))
    end
    -- 最小化/恢复:画布恒定全屏、坐标屏幕锚定(内容无位移)、头部遮挡/露出
    local ok_min, err_min = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        -- 画一笔进元素栈
        table.insert(canvas.elements, {
            kind = "line", x0 = 10, y0 = 10, x1 = 100, y1 = 100, gray = 1.0, width = 4,
        })
        canvas:_renderAll()
        local full_h = canvas.canvas_h -- 恒定全屏 720
        -- 内容包围盒(导出裁剪用):line (10,10)-(100,100) + 8px 边距
        local bbox = canvas:_contentBBox()
        if not (bbox and bbox.x == 2 and bbox.y == 2 and bbox.w == 107 and bbox.h == 107) then
            error("bbox check failed: " .. tostring(bbox and (bbox.x .. "," .. bbox.y .. " " .. bbox.w .. "x" .. bbox.h)))
        end
        print("content bbox:", bbox.w, "x", bbox.h)
        -- 画布坐标 = 屏幕坐标:同一屏幕坐标在两种模式下映射一致 → 无位移
        local x1, y1 = canvas:_toCanvas(30, 200)
        canvas:_setMinimized(true)
        if canvas._minimized ~= true or canvas.canvas_h ~= full_h or canvas.header_h ~= 0 then
            error("minimize failed: header=" .. tostring(canvas.header_h)
                .. " canvas_h=" .. tostring(canvas.canvas_h))
        end
        print("minimized: header_h=", canvas.header_h, "canvas=", canvas.canvas_w, "x", canvas.canvas_h)
        -- 最小化后顶部(原工具栏区域)可画
        local tx, ty = canvas:_toCanvas(30, 30)
        if not (tx == 30 and ty == 30) then
            error("minimized top area not drawable: ", tostring(tx), tostring(ty))
        end
        local x2, y2 = canvas:_toCanvas(30, 200)
        canvas:_setMinimized(false)
        local x3, y3 = canvas:_toCanvas(30, 200)
        -- v57c 自制工具栏高度可调,header 断言改相对(= 工具栏+状态栏)而非硬编码像素
        if canvas._minimized ~= false
            or canvas.header_h ~= canvas.toolbar_h + canvas.status_h then
            error("restore failed: header=" .. tostring(canvas.header_h)
                .. " toolbar=" .. tostring(canvas.toolbar_h)
                .. " status=" .. tostring(canvas.status_h))
        end
        -- 无位移:三种状态映射必须一致
        if not (x1 == 30 and y1 == 200 and x2 == 30 and y2 == 200 and x3 == 30 and y3 == 200) then
            error("no-shift check failed: " .. tostring(x1) .. "," .. tostring(y1)
                .. " / " .. tostring(x2) .. "," .. tostring(y2)
                .. " / " .. tostring(x3) .. "," .. tostring(y3))
        end
        -- 可见模式下底部(工具栏/状态栏)遮挡区不可画(顶部已可画)
        if canvas:_toCanvas(30, 30) == nil then
            error("visible mode top area should be drawable (bottom toolbar)")
        end
        if canvas:_toCanvas(30, canvas.canvas_h - 1) then
            error("visible mode bottom toolbar area should not be drawable")
        end
        print("no-shift: (30,200) -> canvas (30,200) in both modes")
        print("restored: header_h=", canvas.header_h, "canvas_h=", canvas.canvas_h)
    end)
    if ok_min then
        print("PASS: minimize/restore OK")
    else
        print("FAIL: minimize/restore:", tostring(err_min))
        os.exit(1)
    end
    -- 元素刷新区域:圆应覆盖完整范围(圆心±半径+线宽),而非仅锚点-释放点包围盒
    local ok_reg, err_reg = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        local reg = canvas:_elementRegion({ kind = "circle", cx = 100, cy = 100, r = 60, width = 8 })
        if not (reg and reg.w >= 130 and reg.h >= 130) then
            error("circle region too small: " .. tostring(reg and (reg.w .. "x" .. reg.h)))
        end
        print("circle element region:", reg.w, "x", reg.h)
    end)
    if ok_reg then
        print("PASS: element region covers full circle")
    else
        print("FAIL: element region:", tostring(err_reg))
        os.exit(1)
    end
    -- 灰度/粗细长按:切换 固定/随机 模式(反色已被随机分级模型替代)
    local ok_gray, err_gray = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        if canvas.gray_random ~= false then
            error("default gray_random should be false")
        end
        canvas:_toggleGrayRandom()
        if canvas.gray_random ~= true then
            error("gray random toggle on failed")
        end
        canvas:_toggleGrayRandom()
        if canvas.gray_random ~= false then
            error("gray random toggle off failed")
        end
        canvas:_toggleWidthRandom()
        if canvas.width_random ~= true then
            error("width random toggle on failed")
        end
        canvas:_toggleWidthRandom()
        if canvas.width_random ~= false then
            error("width random toggle off failed")
        end
        print("gray/width random toggle OK")
    end)
    if ok_gray then
        print("PASS: gray/width random toggle")
    else
        print("FAIL: gray/width random toggle:", tostring(err_gray))
        os.exit(1)
    end
    -- 快速拖动(swipe)画圆/画线也应落盘
    local ok_sw, err_sw = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 350 } })
        if #canvas.elements ~= 1 then
            error("swipe circle not committed")
        end
        canvas:_setTool("brush")
        canvas:onSwipe(nil, { pos = { x = 50, y = 300 }, end_pos = { x = 150, y = 350 } })
        if #canvas.elements ~= 2 then
            error("swipe brush not committed")
        end
        print("swipe: circle + brush committed OK")
    end)
    if ok_sw then
        print("PASS: swipe gestures OK")
    else
        print("FAIL: swipe:", tostring(err_sw))
        os.exit(1)
    end
    -- 图形工具停留 1s 预览:定时回调生成预览,收笔后清除并落盘
    local ok_pv, err_pv = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("circle")
        canvas:_trackShapeAnchor({ pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:_scheduleShapePreview(200, 350) -- 模拟继续拖动到 (200,350)
        canvas:_maybeShowShapePreview()        -- 定时器到点:显示预览
        if not (canvas.preview and canvas.preview.kind == "circle") then
            error("preview not shown")
        end
        if canvas._shape_preview_region == nil then
            error("preview region missing")
        end
        print("preview region:", canvas._shape_preview_region.w, "x", canvas._shape_preview_region.h)
        canvas:_commitShape(200, 350)
        if canvas.preview or #canvas.elements ~= 1 then
            error("commit after preview failed")
        end
        print("preview shown + committed OK")
    end)
    if ok_pv then
        print("PASS: 1s-hold preview OK")
    else
        print("FAIL: 1s-hold preview:", tostring(err_pv))
        os.exit(1)
    end
    -- 橡皮删除对象 + 撤销/重做 + 点按删除
    local ok_er, err_er = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 350 } })
        canvas:onSwipe(nil, { pos = { x = 300, y = 300 }, end_pos = { x = 380, y = 360 } })
        if #canvas.elements ~= 2 then error("setup failed: " .. #canvas.elements) end
        -- 框选删除两个圆
        canvas:_setTool("eraser")
        canvas.eraser_mode = "rect"
        canvas:_eraseInRect(50, 250, 400, 400)
        if #canvas.elements ~= 0 then error("erase failed: " .. #canvas.elements) end
        -- 撤销恢复两个圆
        canvas:_undo()
        if #canvas.elements ~= 2 then error("undo restore failed: " .. #canvas.elements) end
        -- 重做再删
        canvas:_redo()
        if #canvas.elements ~= 0 then error("redo erase failed: " .. #canvas.elements) end
        -- 画第三个圆后点按删除
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 350 } })
        if #canvas.elements ~= 1 then error("circle3 failed: " .. #canvas.elements) end
        canvas:_setTool("eraser")
        local ok_tap = canvas:_eraseAt(212, 300) -- 圆右缘(墨迹上)
        if not ok_tap or #canvas.elements ~= 0 then
            error("tap erase failed")
        end
        print("object erase + undo/redo + tap delete OK")
    end)
    if ok_er then
        print("PASS: eraser object-delete OK")
    else
        print("FAIL: eraser object-delete:", tostring(err_er))
        os.exit(1)
    end
    -- 画笔:hold_release 收笔后快速起笔,不应连到上一笔
    local ok_hold, err_hold = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("brush")
        -- 第一笔:pan 后以 hold_release 收尾(模拟收笔前短暂停留)
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 300 } })
        canvas:onHoldRelease(nil, { pos = { x = 220, y = 360 } })
        if #canvas.elements ~= 1 or canvas._stroke ~= nil then
            error("hold_release did not finish stroke")
        end
        -- 第二笔(快速):独立新笔画,起点应为按下点
        canvas:onPan(nil, { pos = { x = 300, y = 400 }, start_pos = { x = 300, y = 400 } })
        canvas:onPan(nil, { pos = { x = 400, y = 450 }, start_pos = { x = 300, y = 400 } })
        canvas:onPanRelease(nil, { pos = { x = 420, y = 460 } })
        if #canvas.elements ~= 2 then
            error("second stroke not separate: " .. #canvas.elements)
        end
        local s2 = canvas.elements[2]
        if not (s2.points[1].x == 300 and s2.points[1].y == 400) then
            error("second stroke connected to first: start="
                .. tostring(s2.points[1].x) .. "," .. tostring(s2.points[1].y))
        end
        print("hold_release finish + quick next stroke OK")
    end)
    if ok_hold then
        print("PASS: hold_release stroke bug fixed")
    else
        print("FAIL: hold_release stroke:", tostring(err_hold))
        os.exit(1)
    end
    -- 橡皮点选:最靠近点击点墨迹的对象(而非包围盒最上层)
    local ok_pk, err_pk = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } }) -- 圆A 中心(200,300) r=100
        canvas:_setTool("line")
        canvas:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 210, y = 300 } }) -- 短线B 穿过圆心
        if #canvas.elements ~= 2 then error("setup failed: " .. #canvas.elements) end
        canvas:_setTool("eraser")
        -- 点击圆心:短线B 墨迹距离≈0,圆A 墨迹距离≈r → 应删除短线B(即使圆A包围盒含该点)
        local ok_del = canvas:_eraseAt(200, 300)
        if not ok_del or #canvas.elements ~= 1 then
            error("closest-ink pick failed: " .. #canvas.elements)
        end
        if canvas.elements[1].kind ~= "circle" then
            error("should delete the line, got: " .. canvas.elements[1].kind)
        end
        -- 点空白处(离墨迹超容差)不应删除
        local ok_none = canvas:_eraseAt(30, 30)
        if ok_none or #canvas.elements ~= 1 then
            error("empty tap should not delete")
        end
        -- 点在圆轮廓上应删除圆
        local ok_edge = canvas:_eraseAt(300, 300) -- 圆右缘
        if not ok_edge or #canvas.elements ~= 0 then
            error("on-ink tap should delete")
        end
        print("closest-ink pick: line vs circle-overlap + empty + outline OK")
    end)
    if ok_pk then
        print("PASS: eraser closest-ink pick OK")
    else
        print("FAIL: eraser closest-ink pick:", tostring(err_pk))
        os.exit(1)
    end
    -- 橡皮对画笔生效:墨迹点选/框选都能删掉自由笔画(kind=freehand)
    local ok_bx, err_bx = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 220, y = 360 } })
        if #canvas.elements ~= 1 or canvas.elements[1].kind ~= "freehand" then
            error("brush stroke kind should be freehand, got: "
                .. tostring(canvas.elements[1] and canvas.elements[1].kind))
        end
        -- 点墨迹(路径中点)删除
        canvas:_setTool("eraser")
        local ok_tap = canvas:_eraseAt(150, 325)
        if not ok_tap or #canvas.elements ~= 0 then
            error("eraser tap on brush failed")
        end
        -- 重画后框选删除
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPan(nil, { pos = { x = 400, y = 350 }, start_pos = { x = 300, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 420, y = 360 } })
        canvas:_setTool("eraser")
        canvas:_eraseInRect(280, 280, 440, 380)
        if #canvas.elements ~= 0 then
            error("eraser rect on brush failed")
        end
        print("eraser on brush: tap + rect OK")
    end)
    if ok_bx then
        print("PASS: eraser works on brush strokes")
    else
        print("FAIL: eraser on brush:", tostring(err_bx))
        os.exit(1)
    end
    -- 保存:不闪退(回归 lfs 加载修复)
    local ok_sv, err_sv = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 100, y = 300 } })
        canvas:_save()
    end)
    if ok_sv then
        print("PASS: save (no crash)")
    else
        print("FAIL: save:", tostring(err_sv))
        os.exit(1)
    end
    -- 画笔起笔停留 0.5s 显示起点(onHold 创建进行中笔画,不直接提交)
    local ok_hold_start, err_hold_start = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        canvas:_setTool("brush")
        -- 1. onHold 创建进行中笔画,起点不入元素栈
        canvas:onHold(nil, { pos = { x = 150, y = 350 } })
        if canvas._stroke == nil then
            error("hold should create in-progress stroke")
        end
        if #canvas.elements ~= 0 then
            error("hold should not commit element immediately: " .. #canvas.elements)
        end
        if #canvas._stroke.points ~= 1 or canvas._stroke.points[1].x ~= 150 or canvas._stroke.points[1].y ~= 350 then
            error("hold stroke start point wrong")
        end
        -- 2. hold_release 收笔,整体落盘为单点
        canvas:onHoldRelease(nil, { pos = { x = 150, y = 350 } })
        if #canvas.elements ~= 1 then
            error("hold_release did not commit: " .. #canvas.elements)
        end
        local dot = canvas.elements[1]
        if dot.kind ~= "freehand" or #dot.points ~= 1
            or dot.points[1].x ~= 150 or dot.points[1].y ~= 350 then
            error("dot element wrong")
        end
        -- 3. 撤销
        canvas:_undo()
        if #canvas.elements ~= 0 then
            error("dot undo failed")
        end
        print("hold start dot + undo OK")
        -- 4. hold + hold_pan + hold_release:起点显示后拖动成线,同一笔画
        canvas:onHold(nil, { pos = { x = 100, y = 300 } })
        canvas:onHoldPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 300 } })
        canvas:onHoldRelease(nil, { pos = { x = 220, y = 360 } })
        if #canvas.elements ~= 1 then
            error("hold+pan+release did not commit: " .. #canvas.elements)
        end
        local stroke = canvas.elements[1]
        if stroke.kind ~= "freehand" or #stroke.points < 2 then
            error("stroke should have multiple points: " .. #stroke.points)
        end
        if stroke.points[1].x ~= 100 or stroke.points[1].y ~= 300 then
            error("stroke start point should be hold point")
        end
        print("hold + pan + release line OK")
    end)
    if ok_hold_start then
        print("PASS: brush hold start point")
    else
        print("FAIL: brush hold start point:", tostring(err_hold_start))
        os.exit(1)
    end
else
    print("WARN: DrawingCanvas construct failed (GUI 环境再验):", tostring(err))
end
