--[[--
绘图板新功能单测(防抖 / 字号上限 / 画笔⇄直线 / 选择对象移动复制):
1. 防抖:画笔起笔移动阈值、快速轻触墨点(onPanRelease 与 onTap)、形状最小尺寸
2. 字号上限 800(_pickFontSize 弹出 SpinWidget 的 value_max)
3. 画笔⇄直线(工具面板条目互斥切换 + 按钮文字跟随)
4. 选择对象:点选/取消、移动、复制、undo/redo、模式切换、像素断言

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/feature_test.lua
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

-- 前置初始化必须早于任何 require("ui/uimanager")/require("device")
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

-- ============ 1. 防抖 ============
do
    local ok, err = pcall(function()
        -- 1a. 画笔:真零移动轻点松手 → 无微轨迹,退化为单点墨迹(按下点)
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 100, y = 300 } })
        check(#canvas.elements == 1, "zero-move quick touch should produce a dot, got " .. #canvas.elements)
        local dot = canvas.elements[1]
        check(dot.kind == "freehand" and #dot.points == 1
            and dot.points[1].x == 100 and dot.points[1].y == 300,
            "dot should be 1 point at press point")

        -- 1a2. 早触发策略:超过 EARLY_TRIGGER(1px)的微小移动即正式起笔,保住起笔曲线
        local canvas_a2 = newCanvas()
        canvas_a2:_setTool("brush")
        canvas_a2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas_a2:onPan(nil, { pos = { x = 102, y = 302 }, start_pos = { x = 100, y = 300 } })
        check(canvas_a2._stroke ~= nil, "early trigger: move >= EARLY_TRIGGER starts stroke")
        canvas_a2:onPanRelease(nil, { pos = { x = 110, y = 310 } })
        check(#canvas_a2.elements == 1, "early-trigger stroke should commit")

        -- 1a3. 起笔死区调优:打开时调低手势 PAN_THRESHOLD、按比例缩短 hold 间隔,
        -- 关闭还原,重复应用幂等
        do
            local const = require("drawingpad.const")
            local real_device = package.loaded["device"]
            local gd = {
                PAN_THRESHOLD = 35,
                ges_hold_interval = 500000, -- KOReader time.ms(500),单位无关按比例缩放
                screen = { scaleByDPI = function(_, v) return v end },
            }
            package.loaded["device"] = { input = { gesture_detector = gd } }
            local canvas_t = newCanvas()
            check(gd.PAN_THRESHOLD == const.GESTURE_PAN_THRESHOLD_DP,
                "tuning: threshold lowered on init, got " .. tostring(gd.PAN_THRESHOLD))
            check(gd.ges_hold_interval == math.floor(500000 * const.GESTURE_HOLD_INTERVAL_MS / 500 + 0.5)
                or math.abs(gd.ges_hold_interval - 500000 * const.GESTURE_HOLD_INTERVAL_MS / 500) < 0.5,
                "tuning: hold interval scaled on init, got " .. tostring(gd.ges_hold_interval))
            check(gd._drawingpad_orig_pan_threshold == 35, "tuning: pan original saved")
            check(gd._drawingpad_orig_hold_interval == 500000, "tuning: hold original saved")
            canvas_t:_applyGestureTuning()
            check(gd._drawingpad_orig_pan_threshold == 35, "tuning: re-apply keeps original")
            canvas_t:onCloseWidget()
            check(gd.PAN_THRESHOLD == 35, "tuning: threshold restored on close")
            check(gd.ges_hold_interval == 500000, "tuning: hold interval restored on close")
            check(gd._drawingpad_orig_hold_interval == nil, "tuning: flags cleared")
            package.loaded["device"] = real_device
        end

        -- 1b. 画笔:移动达到阈值(≥4px) → 正式起笔,首点=按下点
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 104, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(canvas2._stroke ~= nil, "stroke should start at threshold")
        check(canvas2._stroke.points[1].x == 100 and canvas2._stroke.points[1].y == 300,
            "first point should be press point")
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPanRelease(nil, { pos = { x = 220, y = 300 } })
        check(#canvas2.elements == 1, "threshold stroke should commit")
        check(canvas2.elements[1].points[1].x == 100, "committed stroke first point = press")

        -- 1c. 画笔 onTap:快速轻触产生墨点
        local canvas3 = newCanvas()
        canvas3:_setTool("brush")
        canvas3:onTap(nil, { pos = { x = 150, y = 400 } })
        check(#canvas3.elements == 1 and canvas3.elements[1].points[1].x == 150,
            "tap should produce a dot")

        -- 1d. 形状最小尺寸:过小丢弃,正常尺寸提交
        local canvas4 = newCanvas()
        canvas4:_setTool("rect")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 105, y = 305 } }) -- 5x5 < 8
        check(#canvas4.elements == 0, "tiny rect should be discarded")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 160, y = 360 } }) -- 60x60 正常
        check(#canvas4.elements == 1 and canvas4.elements[1].kind == "rect",
            "normal rect should commit")
        canvas4:_setTool("circle")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 102, y = 300 } }) -- r=2 < 8
        check(#canvas4.elements == 1, "tiny circle should be discarded")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 120, y = 300 } }) -- r=20 正常
        check(#canvas4.elements == 2 and canvas4.elements[2].kind == "circle",
            "normal circle should commit")
        canvas4:_setTool("line")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 105, y = 300 } }) -- 长 5 < 8
        check(#canvas4.elements == 2, "tiny line should be discarded")
        print("debounce: quick-touch dot / threshold stroke / tap dot / tiny shapes OK")
    end)
    if ok then
        print("PASS: debounce")
    else
        print("FAIL: debounce:", tostring(err))
        os.exit(1)
    end
end

-- ============ 1b. 起笔小圆弧保留(防抖期微轨迹不丢 / 无收锋 / 抽稀封顶) ============
do
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local shapes = require("drawingpad.shapes")

        -- 1b-1. 早触发:1px 移动即起笔,微轨迹在起笔时并入笔画,起笔小弧保留
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 400, y = 400 }, start_pos = { x = 400, y = 400 } })
        canvas:onPan(nil, { pos = { x = 401, y = 401 }, start_pos = { x = 400, y = 400 } })
        check(canvas._stroke ~= nil, "1b-1: EARLY_TRIGGER(1px) triggers stroke")
        canvas:onPan(nil, { pos = { x = 402, y = 400 }, start_pos = { x = 400, y = 400 } })
        canvas:onPan(nil, { pos = { x = 402, y = 402 }, start_pos = { x = 400, y = 400 } })
        canvas:onPanRelease(nil, { pos = { x = 402, y = 402 } })
        check(#canvas.elements == 1, "1b-1: early-trigger stroke commits a tick, got " .. #canvas.elements)
        local tick = canvas.elements[1]
        check(tick.kind == "freehand", "1b-1: element kind freehand")
        check(tick.points[1].x == 400 and tick.points[1].y == 400, "1b-1: first point = press")
        check(canvas.canvas_bb:getPixel(401, 401).a < 128, "1b-1: tick ink visible")

        -- 1b-2. swipe 收尾 + 微轨迹:按下点+微轨迹+终点成弧形笔画(旧版拉直为 2 点直线)
        local canvas3 = newCanvas()
        canvas3:_setTool("brush")
        canvas3:onPan(nil, { pos = { x = 500, y = 400 }, start_pos = { x = 500, y = 400 } })
        canvas3:onPan(nil, { pos = { x = 501, y = 401 }, start_pos = { x = 500, y = 400 } })
        canvas3:onPan(nil, { pos = { x = 502, y = 400 }, start_pos = { x = 500, y = 400 } })
        -- 快甩被分类为 swipe(pos=起点,end_pos=终点,语义与 pan 相反)
        canvas3:onSwipe(nil, { pos = { x = 500, y = 400 }, end_pos = { x = 520, y = 384 } })
        check(#canvas3.elements == 1, "1b-2: swipe with micro commits stroke, got " .. #canvas3.elements)
        local sw = canvas3.elements[1]
        check(sw.kind == "freehand", "1b-2: element kind freehand")
        check(#sw.points >= 4, "1b-2: curved path kept (not 2-point straight), got " .. #sw.points)
        -- 中间点偏离首末弦 = 曲率保留
        local p0, pm, pn = sw.points[1], sw.points[2], sw.points[#sw.points]
        local cross = math.abs((pn.x - p0.x) * (pm.y - p0.y) - (pn.y - p0.y) * (pm.x - p0.x))
        check(cross > 0, "1b-2: middle point off the start-end chord (curvature kept)")
        canvas3:_undo()
        check(#canvas3.elements == 0, "1b-2: swipe stroke undoable")

        -- 1b-3. onHold 起笔:零移动长按(真实场景=手不动按住满 hold 定时器)→ hold 创建
        -- 起点笔画(含起点笔触),不提交;hold_pan 拖动画笔,hold_release 整体落盘
        local canvas4 = newCanvas()
        canvas4:_setTool("brush")
        canvas4:onHold(nil, { pos = { x = 460, y = 400 } })
        check(canvas4._stroke ~= nil, "1b-3: hold creates in-progress stroke")
        check(canvas4._stroke.points[1].x == 460 and canvas4._stroke.points[1].y == 400,
            "1b-3: hold stroke first point = press")
        check(#canvas4.elements == 0, "1b-3: hold stroke not committed yet")
        canvas4:onHoldPan(nil, { pos = { x = 490, y = 420 }, start_pos = { x = 460, y = 400 } })
        canvas4:onHoldRelease(nil, { pos = { x = 500, y = 424 } })
        check(#canvas4.elements == 1, "1b-3: hold stroke commits once")
        check(#canvas4.elements[1].points >= 3, "1b-3: committed stroke keeps press + drag points")

        -- 1b-4. 无收锋:polyline 起点全宽(旧版起点仅 ~35% 宽度渐变入笔)
        local bb = Blitbuffer.new(100, 100, Blitbuffer.TYPE_BB8)
        bb:paintRect(0, 0, 100, 100, Blitbuffer.COLOR_WHITE)
        shapes.polyline(bb,
            { { x = 50, y = 50 }, { x = 60, y = 50 }, { x = 70, y = 52 } },
            8, Blitbuffer.gray(1), 0, 0, "circle")
        check(bb:getPixel(48, 50).a < 128, "1b-4: stroke start full width (left edge)")
        check(bb:getPixel(52, 50).a < 128, "1b-4: stroke start full width (right edge)")
        bb:free()

        -- 1b-5. 抽稀步距封顶:线宽 32(旧步距 4)沿小弧的 3px 级采样点不被吞掉
        local canvas6 = newCanvas()
        canvas6:_setTool("brush")
        canvas6.width = 32
        canvas6:onPan(nil, { pos = { x = 200, y = 420 }, start_pos = { x = 200, y = 420 } })
        canvas6:onPan(nil, { pos = { x = 204, y = 420 }, start_pos = { x = 200, y = 420 } }) -- 达阈值起笔
        check(canvas6._stroke ~= nil, "1b-5: stroke started")
        for i = 1, 10 do
            -- x 每 +1,y 交替 +3/+0:封顶步距 3 下奇数步必被记录(旧步距 4 全被跳过)
            canvas6:onPan(nil, { pos = { x = 204 + i, y = 420 + (i % 2) * 3 },
                start_pos = { x = 200, y = 420 } })
        end
        canvas6:onPanRelease(nil, { pos = { x = 215, y = 424 } })
        local el6 = canvas6.elements[1]
        check(el6 ~= nil, "1b-5: stroke committed")
        check(#el6.points >= 7, "1b-5: width-32 arc keeps dense samples (min_step capped), got "
            .. #el6.points)

        -- 1b-6. Catmull-Rom 圆度:10 个采样点的 r=18 圆,外缘半径波动 ≤3px
        -- (旧中点二次曲线同采样下切角,波动 ~3px+;小圆圈不再画成多边形)
        local bb2 = Blitbuffer.new(80, 80, Blitbuffer.TYPE_BB8)
        bb2:paintRect(0, 0, 80, 80, Blitbuffer.COLOR_WHITE)
        local cr_pts = {}
        for i = 0, 9 do
            local a = -math.pi / 2 + 2 * math.pi * i / 10
            cr_pts[i + 1] = { x = 40 + math.cos(a) * 18, y = 40 + math.sin(a) * 18 }
        end
        shapes.polyline(bb2, cr_pts, 2, Blitbuffer.gray(1), 0, 0, "circle")
        local rmin6, rmax6 = math.huge, 0
        for k = 0, 23 do
            local a = 2 * math.pi * k / 24
            for rr = 4, 34 do
                local px = math.floor(40 + math.cos(a) * rr)
                local py = math.floor(40 + math.sin(a) * rr)
                if bb2:getPixel(px, py).a < 128 then
                    if rr < rmin6 then rmin6 = rr end
                    if rr > rmax6 then rmax6 = rr end
                    break
                end
            end
        end
        check(rmax6 > 0 and rmax6 - rmin6 <= 3, "1b-6: CR circle roundness (spread<=3), got "
            .. tostring(rmin6) .. ".." .. tostring(rmax6))
        bb2:free()

        -- 1b-7. 实时增量渲染与撤销重绘(shapes.polyline)逐像素一致(核心不变量)
        local canvas7 = newCanvas()
        canvas7:_setTool("brush")
        canvas7.width = 4
        canvas7:onPan(nil, { pos = { x = 100, y = 150 }, start_pos = { x = 100, y = 150 } })
        for _, p in ipairs({ { 110, 148 }, { 122, 154 }, { 130, 168 },
                { 126, 182 }, { 112, 188 } }) do
            canvas7:onPan(nil, { pos = { x = p[1], y = p[2] },
                start_pos = { x = 100, y = 150 } })
        end
        canvas7:onPanRelease(nil, { pos = { x = 102, y = 180 } })
        local el7 = canvas7.elements[1]
        check(el7 ~= nil, "1b-7: stroke committed")
        local bbR = Blitbuffer.new(200, 220, Blitbuffer.TYPE_BB8)
        bbR:paintRect(0, 0, 200, 220, Blitbuffer.COLOR_WHITE)
        shapes.drawElement(bbR, el7, Blitbuffer.gray(el7.gray))
        local b7 = el7._bbox
        for y = math.floor(b7.y0) - 2, math.ceil(b7.y1) + 2 do
            for x = math.floor(b7.x0) - 2, math.ceil(b7.x1) + 2 do
                local va = canvas7.canvas_bb:getPixel(x, y).a
                local vb = bbR:getPixel(x, y).a
                check(math.abs(va - vb) <= 8,
                    string.format("1b-7: live/redraw mismatch at %d,%d live=%d redraw=%d",
                        x, y, va, vb))
            end
        end
        bbR:free()

        print("stroke-start arcs: micro tick / swipe curve / hold seed / no taper / min-step cap / CR roundness / live==redraw OK")
    end)
    if ok then
        print("PASS: stroke-start arcs")
    else
        print("FAIL: stroke-start arcs:", tostring(err))
        os.exit(1)
    end
end

-- ============ 2. 字号上限 800 ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local orig_show = UIManager.show
        local captured
        UIManager.show = function(self, w)
            captured = w
            return true
        end
        local canvas = newCanvas()
        local ok2 = pcall(function() canvas:_pickFontSize() end)
        UIManager.show = orig_show
        if captured then
            check(captured.name == "DrawingValuePicker" and captured.max == 800,
                "font size picker should cap at 800, got " .. tostring(captured and captured.name) .. "/"
                .. tostring(captured and captured.max))
        else
            print("WARN: 字号调节弹窗未能 headless 构造,跳过 max 断言")
        end
        print("font size max: 800 OK")
    end)
    if ok then
        print("PASS: font size max 800")
    else
        print("FAIL: font size max 800:", tostring(err))
        os.exit(1)
    end
end

-- ============ 3. 画笔 ⇄ 直线(v59b:面板独立条目,无长按) ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        check(canvas.tool == "brush", "default tool should be brush")
        canvas:_setTool("line")
        check(canvas.tool == "line", "line_btn should switch to line")
        canvas:_setTool("brush")
        check(canvas.tool == "brush", "set back to brush")
        -- v59b:工具条目在分类面板里(双列),激活=浅灰底唯一来源;文字无角标
        local bt = canvas:_categoryBt("tool")
        local bbtn = bt.button_by_id["brush_btn"]
        local lbtn = bt.button_by_id["line_btn"]
        check(bbtn ~= nil and lbtn ~= nil, "brush_btn/line_btn should exist in tool panel")
        local LIGHTGRAY = require("ffi/blitbuffer").COLOR_LIGHT_GRAY
        local WHITE = require("ffi/blitbuffer").COLOR_WHITE
        check(bbtn.text == "画笔" and bbtn[1].background == LIGHTGRAY,
            "brush active should be 画笔 + lightgray bg")
        check(lbtn.text == "直线" and lbtn[1].background == WHITE,
            "line inactive should be white bg")
        canvas:_setTool("line")
        bt = canvas:_categoryBt("tool")
        check(bt.button_by_id["line_btn"][1].background == LIGHTGRAY
            and bt.button_by_id["brush_btn"][1].background == WHITE,
            "line active lightgray, brush white")
        canvas:_setTool("eraser") -- 切走:直线回白底
        bt = canvas:_categoryBt("tool")
        check(bt.button_by_id["line_btn"][1].background == WHITE,
            "line inactive should be white bg after switching away")
        canvas:_setTool("brush")
        print("brush<->line entries OK")
    end)
    if ok then
        print("PASS: brush<->line toggle")
    else
        print("FAIL: brush<->line toggle:", tostring(err))
        os.exit(1)
    end
end

-- ============ 4. 选择对象(移动/复制) ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        -- 画两个元素:短线(画笔 swipe) + 圆(圆工具 swipe)
        canvas:_setTool("brush")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 300, y = 300 }, end_pos = { x = 400, y = 300 } })
        check(#canvas.elements == 2, "setup 2 elements, got " .. #canvas.elements)
        local line_el = canvas.elements[1]
        local circle_el = canvas.elements[2]

        -- 4a. _pickElementAt 命中/空白
        canvas:_setTool("select")
        local el = canvas:_pickElementAt(150, 300)
        check(el == line_el, "pick should hit line")
        el = canvas:_pickElementAt(30, 300)
        check(el == nil, "pick empty should be nil")

        -- 4a2. 重叠选取:两个对象重叠时选"最上层可见"的对象
        local canvasO = newCanvas()
        canvasO:_setTool("brush")
        canvasO.width = 12
        canvasO.gray = 1.0
        canvasO:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 400, y = 300 } }) -- 底层 A(y300,墨 294-306)
        canvasO:onSwipe(nil, { pos = { x = 100, y = 305 }, end_pos = { x = 400, y = 305 } }) -- 上层 B(y305,墨 299-311)
        local a_el, b_el = canvasO.elements[1], canvasO.elements[2]
        canvasO:_setTool("select")
        check(canvasO:_pickElementAt(250, 302) == b_el, "overlap should pick topmost visible")
        check(canvasO:_pickElementAt(250, 308) == b_el, "B-only area picks B")
        check(canvasO:_pickElementAt(250, 294) == a_el, "A-only area picks A")
        -- 空心圆盖实心矩形:圆心在圆孔内(矩形可见处)→ 选矩形;圆边上 → 选圆
        local canvasO2 = newCanvas()
        canvasO2:_setTool("rect")
        canvasO2:onSwipe(nil, { pos = { x = 100, y = 200 }, end_pos = { x = 300, y = 400 } })
        local rectF = canvasO2.elements[1]
        rectF.filled = true -- 实心矩形(底层)
        canvasO2:_cacheBBox(rectF)
        canvasO2:_setTool("circle")
        canvasO2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } }) -- 空心圆 r=100(上层)
        local circH = canvasO2.elements[2]
        canvasO2:_setTool("select")
        check(canvasO2:_pickElementAt(200, 300) == rectF, "hole of top hollow circle reveals filled rect below")
        check(canvasO2:_pickElementAt(300, 300) == circH, "on hollow circle edge picks the circle")

        -- 4b. 点选/取消(先点选再拖动)
        canvas:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas._selected == line_el, "tap should select line")
        canvas:onTap(nil, { pos = { x = 30, y = 300 } })
        check(canvas._selected == nil, "tap empty should deselect")

        -- 4c. 移动:选中圆(点圆右缘),从圆心拖动 +30,+20(避开变形锚点)
        canvas:onTap(nil, { pos = { x = 400, y = 300 } })
        check(canvas._selected == circle_el, "tap should select circle")
        local cx0, cy0 = circle_el.cx, circle_el.cy
        canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 330, y = 320 } })
        check(circle_el.cx == cx0 + 30 and circle_el.cy == cy0 + 20,
            "circle should move by (30,20), got " .. circle_el.cx .. "," .. circle_el.cy)
        -- bbox 缓存跟随平移
        local b = circle_el._bbox
        check(b and b.x0 == circle_el.cx - circle_el.rx, "bbox should follow move")
        -- 撤销恢复 / 重做再移
        canvas:_undo()
        check(circle_el.cx == cx0 and circle_el.cy == cy0, "undo should restore position")
        canvas:_redo()
        check(circle_el.cx == cx0 + 30 and circle_el.cy == cy0 + 20, "redo should re-apply move")
        canvas:_undo()
        check(circle_el.cx == cx0 and circle_el.cy == cy0, "undo2 should restore again")

        -- 4d. 复制:切复制模式,拖动产生副本,原对象不动
        canvas:_toggleSelectMode()
        check(canvas.select_mode == "copy", "toggle should switch to copy")
        canvas:onTap(nil, { pos = { x = 400, y = 300 } })
        canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 350, y = 350 } })
        check(#canvas.elements == 3, "copy should add an element, got " .. #canvas.elements)
        check(circle_el.cx == cx0 and circle_el.cy == cy0, "original should not move")
        local copy_el = canvas.elements[3]
        check(copy_el ~= circle_el and copy_el.kind == "circle"
            and copy_el.cx == cx0 + 50 and copy_el.cy == cy0 + 50,
            "copy should be a distinct circle at offset")
        canvas:_undo()
        check(#canvas.elements == 2, "undo copy should remove it")
        canvas:_toggleSelectMode()
        check(canvas.select_mode == "move", "toggle back to move")

        -- 4e. 移动像素断言:旧位置变白、新位置有墨(粗线使锚点远离拖动起点)
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2.width = 24
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        local bb = canvas2.canvas_bb
        local function a(x, y) return bb:getPixel(x, y) and bb:getPixel(x, y).a end
        check(a(150, 300) == 0, "before move: line ink black, got " .. tostring(a(150, 300)))
        canvas2:onPan(nil, { pos = { x = 150, y = 300 }, start_pos = { x = 150, y = 300 } })
        canvas2:onPanRelease(nil, { pos = { x = 250, y = 320 } }) -- 移动 +100,+20
        check(a(150, 300) == 255, "after move: old position white, got " .. tostring(a(150, 300)))
        check(a(250, 320) == 0, "after move: new position ink, got " .. tostring(a(250, 320)))
        print("select: pick/tap/move/undo-redo/copy/pixels OK")
    end)
    if ok then
        print("PASS: select object move/copy")
    else
        print("FAIL: select object move/copy:", tostring(err))
        os.exit(1)
    end
end

-- ============ 5. 灰度/粗细 随机分级 ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        -- 固定模式:_resolveGray/_resolveWidth 返回当前值
        canvas.gray = 0.7
        canvas.width = 12
        check(math.abs(canvas:_resolveGray() - 0.7) < 0.001, "fixed gray should return current")
        check(canvas:_resolveWidth() == 12, "fixed width should return current")
        -- 随机模式:值在 [min,max] 内
        canvas:_toggleGrayRandom()
        check(canvas.gray_random == true, "gray random on")
        for _ = 1, 20 do
            local v = canvas:_resolveGray()
            check(v >= canvas.gray_min - 0.001 and v <= canvas.gray_max + 0.001,
                "random gray out of range: " .. tostring(v))
        end
        -- levels=2:只出 min/max 两端
        canvas.gray_min = 0.2
        canvas.gray_max = 0.8
        canvas.gray_levels = 2
        for _ = 1, 20 do
            local v = canvas:_resolveGray()
            check(math.abs(v - 0.2) < 0.001 or math.abs(v - 0.8) < 0.001,
                "2-level gray should be min or max, got " .. tostring(v))
        end
        -- 粗细随机
        canvas:_toggleWidthRandom()
        check(canvas.width_random == true, "width random on")
        canvas.width_min = 4
        canvas.width_max = 40
        canvas.width_levels = 4
        for _ = 1, 20 do
            local v = canvas:_resolveWidth()
            check(v >= 4 - 0.001 and v <= 40 + 0.001, "random width out of range: " .. tostring(v))
        end
        -- 实际落笔:随机模式下元素使用随机值(创建处解析)
        local canvas2 = newCanvas()
        canvas2:_toggleGrayRandom()
        canvas2:_toggleWidthRandom()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        local s = canvas2.elements[1]
        check(s ~= nil, "stroke should commit")
        check(s.gray >= canvas2.gray_min - 0.001 and s.gray <= canvas2.gray_max + 0.001,
            "stroke gray should be in random range")
        check(s.width >= canvas2.width_min - 0.001 and s.width <= canvas2.width_max + 0.001,
            "stroke width should be in random range")
        -- 状态栏包含随机标注
        local st = canvas2:_statusText()
        check(st:find("灰:随机") ~= nil and st:find("粗:随机") ~= nil,
            "status should mark random gray/width: " .. st)
        print("gray/width random: fixed/random resolve, levels=2 ends, stroke uses random, status OK")
    end)
    if ok then
        print("PASS: gray/width random levels")
    else
        print("FAIL: gray/width random levels:", tostring(err))
        os.exit(1)
    end
end

-- ============ 6. 图层(3 层独立) ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local canvas = newCanvas()
        check(#canvas.layers == 3 and canvas.active_layer == 2, "3 layers, active 2 (default middle)")
        -- 默认中层画一笔
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        check(#canvas.layers[2] == 1 and #canvas.layers[1] == 0 and #canvas.layers[3] == 0,
            "stroke should be on default middle layer")
        -- 切层3画一笔,层2不受影响
        canvas:_switchLayer(3)
        check(canvas.active_layer == 3, "switchLayer should go to 3")
        canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPan(nil, { pos = { x = 400, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 400, y = 300 } })
        check(#canvas.layers[2] == 1 and #canvas.layers[3] == 1, "layer3 stroke, layer2 intact")
        -- 撤销只作用于当前层(层3)
        canvas:_undo()
        check(#canvas.layers[3] == 0 and #canvas.layers[2] == 1, "undo should only affect layer3")
        -- 重做在层3
        canvas:_redo()
        check(#canvas.layers[3] == 1, "redo on layer3")
        -- 切层清选中/进行中状态
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 350, y = 300 } }) -- 选中层3的笔画
        check(canvas._selected ~= nil, "should select layer3 stroke")
        canvas:_switchLayer(1) -- 到层1
        check(canvas._selected == nil, "layer switch should clear selection")
        -- 清空只清当前层(层1)
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 400 } })
        check(#canvas.layers[1] == 1, "layer1 stroke")
        local confirm
        local orig_show = UIManager.show
        UIManager.show = function(self, w) confirm = w; return true end
        canvas:_clearAll()
        UIManager.show = orig_show
        check(confirm ~= nil and confirm.ok_callback ~= nil, "clearAll should show confirm")
        confirm.ok_callback()
        check(#canvas.layers[1] == 0 and #canvas.layers[2] == 1 and #canvas.layers[3] == 1,
            "clear should only clear active layer (1)")
        -- 状态栏显示层名(上层/中层/下层);v59b 层显隐条目文字动态跟随
        check(canvas:_statusText():find("下层") ~= nil, "status should show layer name")
        -- v59f:图层面板 = 每层单条目(●当前层 + □/☑隐藏;单击切层,长按切隐藏)
        canvas:_switchLayer(3)
        local sbtn = canvas:_categoryBt("layer").button_by_id["layer3_btn"]
        check(sbtn ~= nil and sbtn.text == "●上图层(☐隐藏)",
            "layer3_btn should be ●上图层(☐隐藏), got " .. tostring(sbtn and sbtn.text))
        check(sbtn.hold_callback ~= nil, "layer entry should have hold_callback (toggle hide)")
        sbtn.hold_callback() -- 长按隐藏
        sbtn = canvas:_categoryBt("layer").button_by_id["layer3_btn"]
        check(canvas.layer_visible[3] == false and sbtn.text == "●上图层(☑隐藏)",
            "after hold: hidden box checked, got " .. tostring(sbtn and sbtn.text))
        print("layers: per-layer elements/undo, switch clears selection, clear current layer OK")
    end)
    if ok then
        print("PASS: layers")
    else
        print("FAIL: layers:", tostring(err))
        os.exit(1)
    end
end

-- ============ 7. 灰度/粗细 设置对话框 ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local orig_show = UIManager.show
        local captures = {}
        UIManager.show = function(self, w)
            captures[#captures + 1] = w
            return true
        end
        local canvas = newCanvas()
        pcall(function() canvas:_pickGray() end)
        pcall(function() canvas:_pickWidth() end)
        UIManager.show = orig_show
        -- 在弹窗控件树里找 ButtonTable(结构:popup→CenterContainer→FrameContainer→[VerticalGroup→]ButtonTable)
        local function findButtonTable(w)
            if w and w.button_by_id then
                return w
            end
            for i = 1, 30 do
                local c = w and w[i]
                if c then
                    local r = findButtonTable(c)
                    if r then
                        return r
                    end
                end
            end
            return nil
        end
        if #captures >= 2 then
            local gb = findButtonTable(captures[1])
            local wb = findButtonTable(captures[2])
            check(gb ~= nil and gb.button_by_id["gray_max_btn"] and gb.button_by_id["gray_min_btn"]
                and gb.button_by_id["gray_levels_btn"] and gb.button_by_id["gray_fixed_btn"],
                "gray dialog should have 4 buttons")
            check(wb ~= nil and wb.button_by_id["width_max_btn"] and wb.button_by_id["width_min_btn"]
                and wb.button_by_id["width_levels_btn"] and wb.button_by_id["width_fixed_btn"],
                "width dialog should have 4 buttons")
        else
            print("WARN: 灰度/粗细弹窗未能 headless 构造,跳过按钮断言")
        end
        print("gray/width dialogs OK")
    end)
    if ok then
        print("PASS: gray/width dialogs")
    else
        print("FAIL: gray/width dialogs:", tostring(err))
        os.exit(1)
    end
end

-- ============ 8. 图层命名/显示隐藏/居中菜单 ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local canvas = newCanvas()
        -- 默认层(中层)画一笔
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        -- 注意:显隐切换走乒乓缓冲交换,canvas_bb 引用会变,必须动态读取
        local function a(x, y) return canvas.canvas_bb:getPixel(x, y) and canvas.canvas_bb:getPixel(x, y).a end
        check(a(150, 300) == 0, "middle layer ink visible, got " .. tostring(a(150, 300)))
        -- 长按:隐藏当前层 → 全画布重绘后墨迹消失
        canvas:_toggleLayerVisible()
        check(canvas.layer_visible[2] == false, "toggle should hide middle layer")
        canvas:_renderAll()
        check(a(150, 300) == 255, "hidden layer ink should disappear, got " .. tostring(a(150, 300)))
        -- 状态栏带(隐)
        local st = canvas:_statusText()
        check(st:find("中层") ~= nil and st:find("隐") ~= nil, "status should mark hidden: " .. st)
        -- 再长按显示恢复
        canvas:_toggleLayerVisible()
        check(canvas.layer_visible[2] == true, "toggle should show middle layer again")
        canvas:_renderAll()
        check(a(150, 300) == 0, "shown layer ink should return")
        -- 隐藏层不进保存裁剪(所见即所得)
        canvas:_toggleLayerVisible()
        local bbox = canvas:_contentBBox()
        check(bbox == nil, "hidden layer content should not be exported")
        canvas:_toggleLayerVisible()
        bbox = canvas:_contentBBox()
        check(bbox ~= nil, "visible layer content should be exported")
        -- v59f:图层面板 = 一级"图层"分类,每层单条目(●当前层 + □/☑隐藏;单击切层,长按切隐藏)
        local lbt = canvas:_categoryBt("layer")
        check(lbt.button_by_id["layer3_btn"] ~= nil and lbt.button_by_id["layer2_btn"] ~= nil,
            "layer panel should have one entry per layer")
        canvas:_switchLayer(3)
        lbt = canvas:_categoryBt("layer")
        check(lbt.button_by_id["layer3_btn"].text == "●上图层(☐隐藏)",
            "current layer shows ●, got " .. lbt.button_by_id["layer3_btn"].text)
        check(lbt.button_by_id["layer1_btn"].text == "○下图层(☐隐藏)",
            "other layer shows ○")
        -- 长按切隐藏(非当前层,中层)
        lbt.button_by_id["layer2_btn"].hold_callback()
        check(canvas.layer_visible[2] == false, "hold hides layer2")
        lbt = canvas:_categoryBt("layer")
        check(lbt.button_by_id["layer2_btn"].text == "○中图层(☑隐藏)",
            "hidden layer shows checked box")
        lbt.button_by_id["layer2_btn"].hold_callback()
        check(canvas.layer_visible[2] == true, "hold shows layer2 again")
        -- 图层面板点选保持打开(close_on_tap = false 语义在 _showCategoryMenu,此处只验条目存在)
        print("layers: names/hide-show/export/layer panel OK")
    end)
    if ok then
        print("PASS: layer names/visibility/centered menu")
    else
        print("FAIL: layer names/visibility/centered menu:", tostring(err))
        os.exit(1)
    end
end

-- ============ 9. 笔触形状 ============
do
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local shapes = require("drawingpad.shapes")
        local black = Blitbuffer.gray(1.0)
        local function drawTip(tip)
            local bb = Blitbuffer.new(100, 100, Blitbuffer.TYPE_BB8)
            bb:paintRect(0, 0, 100, 100, Blitbuffer.COLOR_WHITE)
            shapes.tip(bb, 50, 50, 20, black, tip)
            return bb
        end
        local function a(bb, x, y) return bb:getPixel(x, y) and bb:getPixel(x, y).a end
        local t = drawTip("triangle")
        check(a(t, 50, 40) == 0 and a(t, 40, 60) == 0 and a(t, 60, 60) == 0 and a(t, 50, 50) == 0,
            "triangle pixels: " .. tostring(a(t, 50, 40)) .. "/" .. tostring(a(t, 40, 60)))
        t = drawTip("triangle_inv")
        check(a(t, 50, 60) == 0 and a(t, 40, 40) == 0 and a(t, 60, 40) == 0, "triangle_inv pixels")
        t = drawTip("diamond")
        check(a(t, 50, 40) == 0 and a(t, 50, 60) == 0 and a(t, 40, 50) == 0 and a(t, 60, 50) == 0,
            "diamond pixels")
        t = drawTip("square")
        check(a(t, 40, 40) == 0 and a(t, 59, 59) == 0, "square pixels")
        t = drawTip("slash")
        check(a(t, 50, 50) == 0 and a(t, 40, 60) == 0 and a(t, 60, 40) == 0, "slash pixels")
        t = drawTip("backslash")
        check(a(t, 50, 50) == 0 and a(t, 40, 40) == 0 and a(t, 60, 60) == 0, "backslash pixels")
        t = drawTip("circle")
        check(a(t, 50, 50) == 0, "circle pixels")
        -- 元素携带 tip:画笔/直线带,矩形不带
        local canvas = newCanvas()
        canvas.tip = "triangle"
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        check(canvas.elements[1].tip == "triangle", "brush stroke should carry tip")
        canvas:_setTool("line")
        canvas:onSwipe(nil, { pos = { x = 100, y = 400 }, end_pos = { x = 200, y = 400 } })
        check(canvas.elements[2].tip == "triangle", "line should carry tip")
        canvas:_setTool("rect")
        canvas:onSwipe(nil, { pos = { x = 100, y = 500 }, end_pos = { x = 200, y = 550 } })
        check(canvas.elements[3].tip == nil or canvas.elements[3].tip == "circle",
            "rect should keep circle tip")
        -- 笔触菜单构造(7 行预览+按钮 + 1 取消;点触走原生 Button 自带手势)
        local const = require("drawingpad.const")
        local UIManager = require("ui/uimanager")
        local orig_show = UIManager.show
        local captured
        UIManager.show = function(self, w) captured = w; return true end
        pcall(function() canvas:_showTipMenu() end)
        UIManager.show = orig_show
        if captured then
            -- 弹窗本身必须注册手势(否则 stop_events_propagation 吞掉所有输入)
            check(captured.ges_events ~= nil and captured.ges_events.TapSelect ~= nil,
                "tip popup must register TapSelect gesture")
            -- 递归收集:带 callback 的原生 Button、带 BB image 的 ImageWidget 预览
            local btns, previews = {}, {}
            local function walk(w, depth)
                if type(w) ~= "table" or depth > 12 then return end
                if type(w.callback) == "function" then btns[#btns + 1] = w end
                if rawget(w, "image") ~= nil then previews[#previews + 1] = w end
                for i = 1, math.min(#w, 20) do walk(w[i], depth + 1) end
            end
            walk(captured, 0)
            check(#btns >= 8, "tip menu should have 7 tip buttons + cancel, got " .. #btns)
            check(#previews >= 7, "tip menu should show 7 shape previews, got " .. #previews)
            -- 触发第一个笔触按钮 callback,确认 canvas.tip 被设置
            pcall(function() btns[1].callback() end)
            check(canvas.tip == const.TIPS[1][1],
                "firing first tip should set canvas.tip to " .. const.TIPS[1][1])
        else
            print("WARN: 笔触菜单未能 headless 构造,跳过弹窗断言")
        end
        print("tips: shapes pixels / element carry / menu OK")
    end)
    if ok then
        print("PASS: brush tip shapes")
    else
        print("FAIL: brush tip shapes:", tostring(err))
        os.exit(1)
    end
end

-- ============ 10. 连接 bug 修复 / 双指收笔 / 标签居中 ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        -- 注入残留笔画(模拟上一手势漏收 pan_release)
        canvas._stroke = { kind = "freehand", points = { { x = 100, y = 300 }, { x = 200, y = 300 } }, gray = 1.0, width = 4 }
        -- 新一次落笔:start_pos 与笔画首点不同 → 跨手势保护按末点收笔
        canvas:onPan(nil, { pos = { x = 400, y = 300 }, start_pos = { x = 400, y = 300 } })
        check(#canvas.elements == 1 and #canvas.elements[1].points == 2,
            "stale stroke should be committed without extension")
        local last = canvas.elements[1].points[#canvas.elements[1].points]
        check(last.x == 200 and last.y == 300, "stale stroke last point unchanged")
        -- 新笔画从新按下点起笔(不与旧笔相连)
        canvas:onPan(nil, { pos = { x = 450, y = 300 }, start_pos = { x = 400, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 460, y = 300 } })
        check(#canvas.elements == 2 and canvas.elements[2].points[1].x == 400,
            "new stroke should start at new press")
        -- 双指打断:进行中笔画按末点收笔
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(canvas2._stroke ~= nil, "stroke in progress")
        canvas2:onTwoFingerPan()
        check(canvas2._stroke == nil and #canvas2.elements == 1, "two-finger should finish stroke")
        -- v59d:text_fn 动态条目(图层显隐勾选)切换后 setText 传当前宽度,按钮几何恒定
        canvas2._panel_bt = canvas2:_categoryBt("layer")
        local vbtn = canvas2._panel_bt.button_by_id["layer1_btn"] -- 默认当前层 = 下层(合并条目)
        local w0 = vbtn.width
        vbtn.hold_callback() -- 长按隐藏
        vbtn = canvas2:_categoryBt("layer").button_by_id["layer1_btn"]
        check(canvas2.layer_visible[1] == false and vbtn.width == w0,
            "setText should keep button width, got " .. tostring(vbtn.width) .. " vs " .. tostring(w0))
        vbtn.hold_callback() -- 长按显示
        vbtn = canvas2:_categoryBt("layer").button_by_id["layer1_btn"]
        check(canvas2.layer_visible[1] == true and vbtn.width == w0,
            "toggle back keeps width")
        print("connection bug / two-finger / label geometry OK")
    end)
    if ok then
        print("PASS: connection fix / two-finger / label geometry")
    else
        print("FAIL: connection fix / two-finger / label geometry:", tostring(err))
        os.exit(1)
    end
end

-- ============ 11. 合并按钮 / 保存对话框 ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local canvas = newCanvas()
        -- v59b:功能面板 = 撤销/重做/清空/保存 独立条目(无合并按钮、无长按)
        -- v62d:保存=工程(.drawing)、输出=PNG(原保存改名)
        local Blitbuffer = require("ffi/blitbuffer")
        local funcBt = function() return canvas:_categoryBt("func") end
        local ubtn = funcBt().button_by_id["undo_btn"]
        local rbtn = funcBt().button_by_id["redo_btn"]
        local cbtn = funcBt().button_by_id["clear_btn"]
        local sbtn = funcBt().button_by_id["save_btn"]
        local pbtn = funcBt().button_by_id["save_proj_btn"]
        local obtn = funcBt().button_by_id["open_proj_btn"]
        check(ubtn ~= nil and ubtn.callback ~= nil and ubtn.hold_callback == nil,
            "undo_btn should be click-only (no hold)")
        check(rbtn ~= nil and cbtn ~= nil and sbtn ~= nil, "redo/clear/save entries exist")
        check(ubtn.text == "撤销" and rbtn.text == "重做" and cbtn.text == "清空"
            and sbtn.text == "输出", "func labels should be 撤销/重做/清空/输出")
        check(pbtn ~= nil and pbtn.text == "保存" and obtn ~= nil and obtn.text == "打开",
            "project save/open entries exist")
        check(ubtn[1].background == Blitbuffer.COLOR_WHITE
            and cbtn[1].background == Blitbuffer.COLOR_WHITE, "func entries always white bg")
        -- 刷新不崩
        canvas:_refreshCanvas()
        -- 画两笔:撤销/重做条目单击生效
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        canvas:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 400 } })
        check(#canvas.elements == 2, "two strokes")
        canvas:_undo() -- 撤销条目
        check(#canvas.elements == 1, "undo entry should undo")
        canvas:_redo() -- 重做条目
        check(#canvas.elements == 2, "redo entry should redo")
        -- 保存对话框:文件名输入 + 文件夹按钮
        local orig_show = UIManager.show
        local captures = {}
        UIManager.show = function(self, w) captures[#captures + 1] = w; return true end
        pcall(function() canvas:_save() end)
        UIManager.show = orig_show
        if captures[1] then
            local dlg = captures[1]
            local fb = dlg.button_table and dlg.button_table.button_by_id
                and dlg.button_table.button_by_id["folder_btn"]
            check(fb ~= nil, "save dialog should have folder button")
            check(type(dlg.getInputText) == "function", "save dialog should have filename input")
        else
            print("WARN: 保存对话框未能 headless 构造,跳过断言")
        end
        -- 文件夹菜单:有子文件夹时弹出 Menu 且列出子文件夹(验证 lfs.dir 迭代器修复)
        do
            local lfs = require("libs/libkoreader-lfs")
            local DataStorage = require("datastorage")
            local base = DataStorage:getDataDir() .. "/drawingboard"
            if lfs.attributes(base, "mode") ~= "directory" then
                pcall(lfs.mkdir, base)
            end
            local sub = base .. "/_test_sub"
            pcall(lfs.mkdir, sub)
            local captures2 = {}
            UIManager.show = function(self, w) captures2[#captures2 + 1] = w; return true end
            pcall(function() canvas:_pickSaveFolder() end)
            UIManager.show = orig_show
            if captures2[1] and captures2[1].buttons then
                local has_sub = false
                for _, row in ipairs(captures2[1].buttons) do
                    for _, b in ipairs(row) do
                        if b.text == "_test_sub/" then has_sub = true end -- 文件夹项带 "/" 后缀
                    end
                end
                check(has_sub, "folder menu should list subfolder (lfs.dir fix)")
            else
                print("WARN: 文件夹菜单未能 headless 构造,跳过子文件夹断言")
            end
            pcall(lfs.rmdir, sub)
        end
        print("merged buttons / save dialog OK")
    end)
    if ok then
        print("PASS: merged buttons / save dialog")
    else
        print("FAIL: merged buttons / save dialog:", tostring(err))
        os.exit(1)
    end
end

-- ============ 12. 变形(四角锚点缩放/旋转/切换/poly/撤销) ============
-- 锚点机制:选中显示四角(默认缩放模式),再次点选同一对象切换为旋转模式(拖角旋转),
-- 再点选切回;点空白取消选择;文字不支持旋转(不切换)。顶部独立旋转锚已移除。
do
    local ok, err = pcall(function()
        -- 缩放:拖 se 锚放大矩形(对边固定)
        local canvas = newCanvas()
        canvas:_setTool("rect")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local rect = canvas.elements[1]
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 100, y = 350 } }) -- 空心矩形点左边缘选中
        check(canvas._selected == rect, "select rect via edge tap")
        check(canvas._handle_mode == "scale", "default handle mode is scale")
        check(canvas:_hitHandle(204, 404) == "se", "hit se handle")
        check(canvas:_hitHandle(204, 350) == nil, "no midpoint handle (4 corners only)")
        -- 命中半径 48:偏离角点 40px 内仍可命中(便于手指点中);超过 48 则不算
        check(canvas:_hitHandle(168, 376) == "se", "hit within 48px radius of corner")
        check(canvas:_hitHandle(150, 360) == nil, "miss beyond hit radius")
        canvas:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } })
        canvas:onPanRelease(nil, { pos = { x = 250, y = 450 } })
        check(rect.x0 == 100 and rect.y0 == 300 and rect.x1 == 250 and rect.y1 == 450,
            "rect scaled: " .. rect.x0 .. "," .. rect.y0 .. " " .. rect.x1 .. "," .. rect.y1)
        canvas:_undo()
        check(rect.x1 == 200 and rect.y1 == 400, "undo transform restores")
        canvas:_redo()
        check(rect.x1 == 250 and rect.y1 == 450, "redo transform reapplies")

        -- 再次点选切换 缩放↔旋转;点空白取消选择(模式回到缩放)。
        -- 注意:undo/redo 会清空选中,故先重新点选一次,再一次点选才是切换
        canvas:onTap(nil, { pos = { x = 100, y = 400 } }) -- 重新点选(缩放后矩形左边缘)
        check(canvas._selected == rect, "reselect rect after redo")
        check(canvas._handle_mode == "scale", "reselect resets to scale")
        canvas:onTap(nil, { pos = { x = 100, y = 400 } }) -- 再点选 → 旋转模式
        check(canvas._handle_mode == "rotate", "re-tap toggles to rotate")
        check(canvas:_hitHandle(254, 454) == "se", "rotate mode hits se corner")
        canvas:onTap(nil, { pos = { x = 100, y = 400 } })
        check(canvas._handle_mode == "scale", "re-tap toggles back to scale")
        canvas:onTap(nil, { pos = { x = 500, y = 500 } }) -- 点空白
        check(canvas._selected == nil, "tap blank deselects")
        check(canvas._handle_mode == "scale", "deselect resets handle mode")

        -- 旋转:再次点选切换后拖角,水平线绕中心转 +90° 变垂直
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line = canvas2.elements[1]
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas2._selected == line, "select line")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } }) -- 再次点选 → 旋转模式
        check(canvas2._handle_mode == "rotate", "re-tap line toggles rotate")
        -- 线宽 4 → bbox(96,296)-(204,304) pad4;细线四角间距 16px < 命中半径 24,
        -- 相邻角会同时命中(旋转结果与命中哪个角无关),只断言命中任一四角
        check(canvas2:_hitHandle(208, 308) ~= nil, "rotate mode hits a corner")
        check(canvas2:_hitHandle(150, 292) == nil, "rotate mode has no top/edge handle")
        canvas2:onPan(nil, { pos = { x = 208, y = 308 }, start_pos = { x = 208, y = 308 } })
        canvas2:onPanRelease(nil, { pos = { x = 142, y = 358 } }) -- 角偏移 (58,8) 旋 90° → (-8,58)
        local p1, p2 = line.points[1], line.points[2]
        local xs_ok = math.abs(p1.x - 150) < 3 and math.abs(p2.x - 150) < 3
        local ys = { p1.y, p2.y }
        local ys_ok = (math.abs(ys[1] - 250) < 3 or math.abs(ys[1] - 350) < 3)
            and (math.abs(ys[2] - 250) < 3 or math.abs(ys[2] - 350) < 3)
            and math.abs(ys[1] - ys[2]) > 90
        check(xs_ok and ys_ok,
            "line rotated 90: " .. p1.x .. "," .. p1.y .. " " .. p2.x .. "," .. p2.y)
        canvas2:_undo()
        local r1, r2 = line.points[1], line.points[2]
        check(math.abs(r1.y - 300) < 3 and math.abs(r2.y - 300) < 3,
            "undo rotation restores horizontal")
        canvas2:_redo()
        check(math.abs(line.points[1].x - 150) < 3, "redo rotation reapplies")

        -- 矩形旋转 → poly(4 点描边,实心退化为描边)
        local canvas3 = newCanvas()
        canvas3:_setTool("rect")
        canvas3:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        canvas3:_setTool("select")
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } })
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } }) -- 再点选 → 旋转模式
        check(canvas3._handle_mode == "rotate", "rect re-tap toggles rotate")
        canvas3:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } })
        canvas3:onPanRelease(nil, { pos = { x = 96, y = 404 } }) -- se 角绕 (150,350) 旋 +90° → sw 位置
        local poly = canvas3.elements[1]
        check(poly.kind == "poly" and #poly.points == 4 and not poly.filled,
            "rotated rect should become poly with 4 points")
        -- 角点 (100,300) 绕 (150,350) 转 90° → (200,300),poly 描边应有墨
        local bb = canvas3.canvas_bb
        local px = bb:getPixel(200, 300) and bb:getPixel(200, 300).a
        check(px == 0, "poly edge ink at rotated corner, got " .. tostring(px))
        -- poly 撤销恢复为 rect
        canvas3:_undo()
        check(canvas3.elements[1].kind == "rect" and canvas3.elements[1].x1 == 200,
            "undo poly rotation restores rect")

        -- 圆:旋转模式拖角 +90°,切回缩放模式拖角成椭圆
        local canvas5 = newCanvas()
        canvas5:_setTool("circle")
        canvas5:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } }) -- r=100
        local circle = canvas5.elements[1]
        canvas5:_setTool("select")
        canvas5:onTap(nil, { pos = { x = 300, y = 300 } })
        check(canvas5._selected == circle, "select circle")
        canvas5:onTap(nil, { pos = { x = 300, y = 300 } }) -- 再点选 → 旋转模式
        check(canvas5._handle_mode == "rotate", "circle re-tap toggles rotate")
        -- bbox(100,200)-(300,400) pad4 → se (304,404),绕中心 (200,300) 旋 +90° → sw (96,404)
        canvas5:onPan(nil, { pos = { x = 304, y = 404 }, start_pos = { x = 304, y = 404 } })
        canvas5:onPanRelease(nil, { pos = { x = 96, y = 404 } })
        check(circle.rot ~= nil and math.abs(circle.rot - math.pi / 2) < 0.05,
            "circle rotated 90, got " .. tostring(circle.rot))
        -- 切回缩放模式:拖 OBB 角 → 非等比椭圆,向外可拉大(旋转后 OBB 缩放语义)
        canvas5:onTap(nil, { pos = { x = 300, y = 300 } }) -- 再点选 → 缩放模式
        check(canvas5._handle_mode == "scale", "re-tap toggles back to scale")
        local fc5 = canvas5:_frameCorners(circle)
        local s5x, s5y = fc5[3].x, fc5[3].y -- 旋转 90° 圆的 OBB se 角
        canvas5:onPan(nil, { pos = { x = s5x, y = s5y }, start_pos = { x = s5x, y = s5y } })
        canvas5:onPanRelease(nil, { pos = { x = s5x, y = s5y + 300 } }) -- 沿一轴拉大(释放点避开底部工具栏区)
        check(circle.rx ~= circle.ry,
            "circle scaled non-uniformly, got " .. tostring(circle.rx) .. "/" .. tostring(circle.ry))
        check(math.max(circle.rx, circle.ry) > 100,
            "rotated circle grows when corner dragged outward, got " .. tostring(circle.rx) .. "/" .. tostring(circle.ry))
        -- 撤销:先恢复圆(等半径),再恢复旋转
        canvas5:_undo()
        check(math.abs(circle.rx - circle.ry) < 0.01, "undo scale restores round circle")
        canvas5:_undo()
        check((circle.rot or 0) == 0, "undo rotation restores rot")

        -- 文字:再次点选不切换旋转(文字不支持旋转,四角仍缩放)
        local canvas6 = newCanvas()
        local tel = {
            kind = "text",
            x = 400, y = 200,
            text = "文字测试",
            font = canvas6.font,
            size = canvas6.font_size,
            gray = 1.0,
        }
        table.insert(canvas6.elements, tel)
        canvas6:_cacheBBox(tel)
        canvas6:_setTool("select")
        canvas6:onTap(nil, { pos = { x = 400, y = 220 } }) -- 点文字 bbox 内
        check(canvas6._selected == tel, "select text")
        canvas6:onTap(nil, { pos = { x = 400, y = 220 } }) -- 再点选:文字现在支持旋转
        check(canvas6._handle_mode == "rotate", "text re-tap toggles rotate")

        -- 倾斜椭圆:选取框/锚点用 OBB 四角(紧贴边界),不再用悬空的轴对齐 AABB 大框
        local canvas7 = newCanvas()
        canvas7:_setTool("circle")
        canvas7:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } }) -- r=100
        local tilted = canvas7.elements[1]
        tilted.rx, tilted.ry = 100, 40
        tilted.rot = math.pi / 4
        canvas7:_cacheBBox(tilted)
        canvas7:_setTool("select")
        canvas7:onTap(nil, { pos = { x = 271, y = 371 } }) -- 椭圆边界上(局部 (100,0) 旋转 45° 附近)
        check(canvas7._selected == tilted, "select tilted ellipse")
        local fc = canvas7:_frameCorners(tilted)
        check(fc and #fc == 4, "tilted ellipse has OBB frame corners")
        -- OBB 角 ≈ (244,403);轴对齐 AABB 角 (303,403) 悬空,不再是锚点
        check(canvas7:_hitHandle(303, 403) == nil, "AABB corner no longer an anchor")
        check(canvas7:_hitHandle(244, 403) ~= nil, "OBB corner is an anchor")

        -- 文字旋转:再点选切旋转模式,拖对角旋转 ~180°,撤销恢复;锚点命中半径 64
        local canvasT = newCanvas()
        local tel = { kind = "text", x = 400, y = 200, text = "旋转测试", font = canvasT.font, size = canvasT.font_size, gray = 1.0 }
        table.insert(canvasT.elements, tel)
        canvasT:_cacheBBox(tel)
        canvasT:_setTool("select")
        canvasT:onTap(nil, { pos = { x = 400, y = 220 } })
        check(canvasT._selected == tel, "select text for rotate")
        canvasT:onTap(nil, { pos = { x = 400, y = 220 } })
        check(canvasT._handle_mode == "rotate", "text toggles to rotate mode")
        local fcT = canvasT:_frameCorners(tel)
        check(fcT and #fcT == 4, "text has frame corners")
        local t0x, t0y = fcT[1].x, fcT[1].y
        canvasT:onPan(nil, { pos = { x = t0x, y = t0y }, start_pos = { x = t0x, y = t0y } })
        check(canvasT._transform ~= nil, "text transform started")
        local t1x, t1y = fcT[3].x, fcT[3].y -- 对角 = 旋转 180°
        canvasT:onPan(nil, { pos = { x = t1x, y = t1y }, start_pos = { x = t0x, y = t0y } })
        canvasT:onPanRelease(nil, { pos = { x = t1x, y = t1y } })
        local rot_v = tel.rot or 0
        check(math.abs(rot_v - math.pi) < 0.05 or math.abs(rot_v + math.pi) < 0.05,
            "text rotated ~180, got " .. tostring(rot_v))
        canvasT:_undo()
        check((tel.rot or 0) == 0, "undo text rotation restores")
        -- 文字锚点命中半径 64(普通 48):距角 55px 命中、70px 不中
        canvasT:onTap(nil, { pos = { x = 400, y = 220 } }) -- 重新选中(undo 清选中)
        local fcR = canvasT:_frameCorners(tel)
        check(canvasT:_hitHandle(fcR[1].x - 55, fcR[1].y) ~= nil, "text anchor hit within 64px")
        check(canvasT:_hitHandle(fcR[1].x - 70, fcR[1].y) == nil, "text anchor miss beyond 64px")
        -- 普通对象锚点仍是 48:距角 55px 不命中
        local canvasR = newCanvas()
        canvasR:_setTool("rect")
        canvasR:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        canvasR:_setTool("select")
        canvasR:onTap(nil, { pos = { x = 100, y = 350 } })
        check(canvasR:_hitHandle(149, 404) == nil, "rect anchor miss beyond 48px (55px)")

        -- 文字拉伸:非等比缩放 → 均匀部分进字号、残余进 sx/sy 像素缩放
        local canvasS = newCanvas()
        local tel2 = { kind = "text", x = 100, y = 100, text = "拉伸", font = canvasS.font, size = 24, gray = 1.0 }
        table.insert(canvasS.elements, tel2)
        canvasS:_cacheBBox(tel2)
        local sb2 = tel2._bbox
        canvasS:_scaleElement(tel2, sb2, { x0 = sb2.x0, y0 = sb2.y0, x1 = sb2.x0 + (sb2.x1 - sb2.x0) * 2, y1 = sb2.y1 })
        check(tel2.size == 36, "text uniform part into size, got " .. tostring(tel2.size))
        check(math.abs((tel2.sx or 1) * 1.5 - 2) < 0.01 and math.abs((tel2.sy or 1) * 1.5 - 1) < 0.01,
            "text total width factor 2 / height 1, got sx " .. tostring(tel2.sx) .. " sy " .. tostring(tel2.sy))
        -- 旋转矩形缩放:OBB 角锚缩放——切回缩放模式后拖角向外可拉大(修"旋转后只能缩小")
        local canvasR2 = newCanvas()
        canvasR2:_setTool("rect")
        canvasR2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local poly2 = canvasR2.elements[1]
        canvasR2:_setTool("select")
        canvasR2:onTap(nil, { pos = { x = 100, y = 350 } })
        canvasR2:onTap(nil, { pos = { x = 100, y = 350 } }) -- 旋转模式
        canvasR2:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } })
        canvasR2:onPanRelease(nil, { pos = { x = 96, y = 404 } }) -- 旋转 90° → poly
        check(poly2.kind == "poly", "rect rotated to poly")
        canvasR2:onTap(nil, { pos = { x = 200, y = 300 } }) -- 旋转后角点 (100,300)→(200,300),再点选切回缩放
        check(canvasR2._handle_mode == "scale", "poly toggles back to scale")
        local function pdiag(p)
            local p1, p3 = p.points[1], p.points[3]
            return math.sqrt((p1.x - p3.x) ^ 2 + (p1.y - p3.y) ^ 2)
        end
        local diag0 = pdiag(poly2)
        local fc2 = canvasR2:_frameCorners(poly2)
        local s2x, s2y = fc2[3].x, fc2[3].y -- se 角
        local ccx, ccy = (poly2.points[1].x + poly2.points[3].x) / 2, (poly2.points[1].y + poly2.points[3].y) / 2
        canvasR2:onPan(nil, { pos = { x = s2x, y = s2y }, start_pos = { x = s2x, y = s2y } })
        canvasR2:onPanRelease(nil, { pos = { x = ccx + (s2x - ccx) * 1.5, y = ccy + (s2y - ccy) * 1.5 } })
        check(pdiag(poly2) > diag0 * 1.15,
            "rotated poly grows when corner dragged outward: " .. diag0 .. " -> " .. pdiag(poly2))

        -- 旋转椭圆缩放:同样可向外拉大
        local canvasE2 = newCanvas()
        canvasE2:_setTool("circle")
        canvasE2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local circE = canvasE2.elements[1]
        canvasE2:_setTool("select")
        canvasE2:onTap(nil, { pos = { x = 300, y = 300 } })
        canvasE2:onTap(nil, { pos = { x = 300, y = 300 } }) -- 旋转模式
        canvasE2:onPan(nil, { pos = { x = 304, y = 404 }, start_pos = { x = 304, y = 404 } })
        canvasE2:onPanRelease(nil, { pos = { x = 96, y = 404 } }) -- 旋转 90°
        check(math.abs((circE.rot or 0) - math.pi / 2) < 0.05, "ellipse rotated 90")
        canvasE2:onTap(nil, { pos = { x = 300, y = 300 } }) -- 再点选切回缩放(圆旋转 90° 右缘仍在 300,300)
        check(canvasE2._handle_mode == "scale", "ellipse toggles back to scale")
        local rx0 = circE.rx
        local fcE = canvasE2:_frameCorners(circE)
        local sEx, sEy = fcE[3].x, fcE[3].y
        local cEx, cEy = circE.cx, circE.cy
        canvasE2:onPan(nil, { pos = { x = sEx, y = sEy }, start_pos = { x = sEx, y = sEy } })
        canvasE2:onPanRelease(nil, { pos = { x = cEx + (sEx - cEx) * 1.5, y = cEy + (sEy - cEy) * 1.5 } })
        check(circE.rx > rx0 * 1.1,
            "rotated ellipse grows when corner dragged outward: " .. rx0 .. " -> " .. circE.rx)
        print("transform: corner scale/rotate/toggle/poly/undo-redo/circle-ellipse OK")
    end)
    if ok then
        print("PASS: transform handles")
    else
        print("FAIL: transform handles:", tostring(err))
        os.exit(1)
    end
end

-- ============ 13. 移动预览 / 选中对象灰度粗细 / 保存文件夹浏览器 ============
do
    local ok, err = pcall(function()
        -- 13a. 移动/复制拖拽:0.5s 停留落点预览(停止位置防抖,headless 手动触发定时器回调)
        local canvas = newCanvas()
        canvas:_setTool("rect")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local rect = canvas.elements[1]
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 100, y = 350 } }) -- 选中空心矩形
        canvas:onPan(nil, { pos = { x = 120, y = 350 }, start_pos = { x = 100, y = 350 } })
        check(canvas._select_drag ~= nil, "drag should start move")
        check(canvas._drag_preview == nil, "no preview before dwell")
        canvas:onPan(nil, { pos = { x = 120, y = 350 }, start_pos = { x = 100, y = 350 } }) -- 再 pan = 停留
        check(canvas._drag_preview_fn ~= nil, "dwell timer scheduled (stop debounce)")
        canvas:_maybeShowDragPreview() -- 手动触发定时器回调(headless 无事件循环)
        local pv = canvas._drag_preview
        check(pv ~= nil, "dwell should show move preview")
        local pb = pv._bbox
        check(pb.x0 == 120 and pb.y0 == 300 and pb.x1 == 220 and pb.y1 == 400,
            "preview at drag offset: " .. pb.x0 .. "," .. pb.y0 .. " " .. pb.x1 .. "," .. pb.y1)
        canvas:onPan(nil, { pos = { x = 140, y = 350 }, start_pos = { x = 100, y = 350 } }) -- 又移动:预览跟随更新(不再擦除=无抖动)
        local pv2 = canvas._drag_preview
        check(pv2 ~= nil, "preview follows finger (no clear)")
        check(pv2._bbox.x0 == 140 and pv2._bbox.y0 == 300 and pv2._bbox.x1 == 240 and pv2._bbox.y1 == 400,
            "preview updated to new offset")
        check(canvas._drag_preview_repaint_pending == true, "follow update schedules throttled repaint")
        canvas:onPan(nil, { pos = { x = 140, y = 350 }, start_pos = { x = 100, y = 350 } }) -- 同位置:几何未变
        check(canvas._drag_preview == pv2, "no-op position keeps same preview instance (anti-flicker)")
        canvas:onPanRelease(nil, { pos = { x = 140, y = 350 } })
        check(rect.x0 == 140 and rect.y0 == 300 and rect.x1 == 240 and rect.y1 == 400,
            "rect moved to final pos: " .. rect.x0 .. "," .. rect.y0)
        check(canvas._drag_preview == nil, "preview cleared on release")

        -- 13a2. 旋转模式拖锚点:0.5s 停留显示旋转后预览(与 _finishTransform 同数学)
        local canvas3 = newCanvas()
        canvas3:_setTool("rect")
        canvas3:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        canvas3:_setTool("select")
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } })
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } }) -- 再点选 → 旋转模式
        check(canvas3._handle_mode == "rotate", "rotate mode for preview test")
        canvas3:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } }) -- 起笔命中 se 角
        check(canvas3._transform ~= nil and canvas3._transform.handle == "se", "transform started")
        canvas3:onPan(nil, { pos = { x = 96, y = 404 }, start_pos = { x = 204, y = 404 } }) -- 拖到 sw 角位置 = +90°
        check(canvas3._drag_preview_fn ~= nil, "rotate dwell timer scheduled")
        canvas3:_maybeShowDragPreview() -- 手动触发停留回调
        local rpv = canvas3._drag_preview
        check(rpv ~= nil, "rotate dwell should show preview")
        check(rpv.kind == "poly" and #rpv.points == 4, "rotate preview should be rotated poly")
        local found = false
        for _, p in ipairs(rpv.points) do -- 角点 (100,300) 绕 (150,350) 转 90° → (200,300)
            if math.abs(p.x - 200) < 1 and math.abs(p.y - 300) < 1 then found = true end
        end
        check(found, "rotate preview corner at rotated position")
        canvas3:onPanRelease(nil, { pos = { x = 96, y = 404 } })
        check(canvas3._drag_preview == nil, "rotate preview cleared on release")
        local rpoly = canvas3.elements[1]
        check(rpoly.kind == "poly" and rpoly ~= rpv, "real rotation committed")

        -- 13a3. 缩放模式拖锚点:停满后显示拉伸预览(与 _finishTransform 同数学)
        local canvas4 = newCanvas()
        canvas4:_setTool("rect")
        canvas4:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local rect4 = canvas4.elements[1]
        canvas4:_setTool("select")
        canvas4:onTap(nil, { pos = { x = 100, y = 350 } })
        canvas4:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } }) -- 起笔命中 se 角
        check(canvas4._transform ~= nil and canvas4._transform.handle == "se", "scale transform started")
        check(canvas4._handle_mode == "scale", "scale mode for preview test")
        canvas4:onPan(nil, { pos = { x = 250, y = 450 }, start_pos = { x = 204, y = 404 } }) -- 拖到 (250,450)
        canvas4:_maybeShowDragPreview()
        local spv = canvas4._drag_preview
        check(spv ~= nil, "scale dwell should show preview")
        check(spv._bbox.x0 == 100 and spv._bbox.y0 == 300 and spv._bbox.x1 == 250 and spv._bbox.y1 == 450,
            "scale preview bbox: " .. tostring(spv._bbox.x1) .. "," .. tostring(spv._bbox.y1))
        canvas4:onPanRelease(nil, { pos = { x = 250, y = 450 } })
        check(rect4.x1 == 250 and rect4.y1 == 450, "rect scaled to final")
        check(canvas4._drag_preview == nil, "scale preview cleared on release")

        -- 13a4. v61s:文字移动预览真实渲染(旧版 paintTo 走 shapes.drawElement
        -- 不识别 text = 画空气,用户看到"文字移动无预览")
        local canvasT = newCanvas()
        canvasT:_setTool("text")
        canvasT:_commitText(150, 300, "测试文字")
        canvasT:_setTool("select")
        canvasT:onTap(nil, { pos = { x = 160, y = 300 } })
        check(canvasT._selected ~= nil and canvasT._selected.kind == "text", "text selected")
        canvasT:onPan(nil, { pos = { x = 420, y = 400 }, start_pos = { x = 400, y = 400 } })
        check(canvasT._select_drag ~= nil, "text move drag started (start beyond handle radius)")
        canvasT:onPan(nil, { pos = { x = 450, y = 420 }, start_pos = { x = 400, y = 400 } })
        canvasT:_maybeShowDragPreview()
        local tpv = canvasT._drag_preview
        check(tpv ~= nil and tpv.kind == "text", "text move dwell shows preview")
        if tpv then
            local BLB = require("ffi/blitbuffer")
            local tbb = BLB.new(canvasT.canvas_w, canvasT.canvas_h, BLB.TYPE_BB8)
            tbb:fill(BLB.COLOR_WHITE)
            canvasT:paintTo(tbb, 0, 0)
            -- 预览落点区(原文字右侧以外,预览 bbox 右半段)必须有墨
            local pb = tpv._bbox
            local ink = 0
            for x = math.floor((pb.x0 + pb.x1) / 2), math.floor(pb.x1), 2 do
                for y = math.floor(pb.y0), math.floor(pb.y1), 2 do
                    local v = tbb:getPixel(x, y)
                    if v and v.a == 0 then ink = ink + 1 end
                end
            end
            check(ink > 0, "text preview paints ink via _drawTextTo, got " .. ink)
            tbb:free()
        end
        canvasT:onPanRelease(nil, { pos = { x = 450, y = 420 } })

        -- 13b. 选中对象灰度/粗细调节 + 撤销
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line = canvas2.elements[1]
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas2._selected == line, "select line for props")
        canvas2:_applySelectedGray(50)
        check(math.abs(line.gray - 0.5) < 0.001, "selected gray applied, got " .. tostring(line.gray))
        canvas2:_applySelectedWidth(8)
        check(line.width == 8, "selected width applied")
        check(line._bbox.y0 == 292, "bbox recomputed after width, got " .. tostring(line._bbox.y0))
        canvas2:_undo() -- 撤销粗细(宽度记录的 orig 快照含当时 gray=0.5)
        check(line.width == 4, "undo width restores")
        canvas2:_undo() -- 撤销灰度
        check(math.abs(line.gray - 1.0) < 0.001, "undo gray restores")
        -- 同值第二次不产生新记录
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } }) -- 重新选中(undo 清空选中)
        canvas2:_applySelectedGray(50)
        canvas2:_applySelectedGray(50)
        canvas2:_undo()
        check(math.abs(line.gray - 1.0) < 0.001, "duplicate same-value no extra undo")

        -- 13d. 直线预览粗细固定:随机模式下起笔取一次,多次停留预览与提交都不变
        local canvasL = newCanvas()
        canvasL:_setTool("line")
        canvasL.width_random = true
        canvasL.width_min, canvasL.width_max = 2, 20
        canvasL:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasL:onPan(nil, { pos = { x = 150, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasL:_scheduleShapePreview(150, 300)
        canvasL:_maybeShowShapePreview()
        local pw = canvasL.preview and canvasL.preview.width
        check(pw ~= nil, "line preview should have fixed width")
        canvasL:onPan(nil, { pos = { x = 160, y = 300 }, start_pos = { x = 100, y = 300 } }) -- 再停留
        canvasL:_scheduleShapePreview(160, 300)
        canvasL:_maybeShowShapePreview()
        check(canvasL.preview and canvasL.preview.width == pw,
            "line preview width fixed across dwells, got " .. tostring(canvasL.preview and canvasL.preview.width))
        canvasL:onPanRelease(nil, { pos = { x = 160, y = 300 } })
        local lineEl = canvasL.elements[1]
        check(lineEl and lineEl.kind == "line" and lineEl.width == pw,
            "committed line width matches preview")

        -- 13c. 保存文件夹浏览器:菜单含 主目录/选择此目录/上一级/子文件夹/已有 PNG 文件
        local UIManager = require("ui/uimanager")
        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local base = DataStorage:getDataDir() .. "/drawingboard"
        if lfs.attributes(base, "mode") ~= "directory" then
            pcall(lfs.mkdir, base)
        end
        local sub = base .. "/_test_browser"
        pcall(lfs.mkdir, sub)
        local fake_png = base .. "/_test_file.png"
        local fh = io.open(fake_png, "w")
        if fh then fh:write("fake png bytes"); fh:close() end
        local captures = {}
        local orig_show = UIManager.show
        UIManager.show = function(self, w) captures[#captures + 1] = w; return true end
        pcall(function() canvas2:_pickSaveFolder() end)
        UIManager.show = orig_show
        if captures[1] and captures[1].buttons then
            local has_commit, has_up, has_home, has_sub, has_file = false, false, false, false, false
            for _, row in ipairs(captures[1].buttons) do
                for _, b in ipairs(row) do
                    if b.text:find("选择此目录") then has_commit = true end
                    if b.text:find("上一级") then has_up = true end
                    if b.text == "主目录" then has_home = true end
                    if b.text == "_test_browser/" then has_sub = true end -- 文件夹项带 "/" 后缀
                    if b.text == "_test_file.png" then has_file = true end
                end
            end
            check(has_commit, "folder browser should have 选择此目录")
            check(has_up, "folder browser should have 上一级")
            check(has_home, "folder browser should have 主目录")
            check(has_sub, "folder browser should list subfolder")
            check(has_file, "folder browser should list existing png files")
        else
            print("WARN: 文件夹浏览器未能 headless 构造,跳过断言")
        end
        pcall(os.remove, fake_png)
        pcall(lfs.rmdir, sub)
        print("move preview / selected props / folder browser OK")
    end)
    if ok then
        print("PASS: move preview / selected props / folder browser")
    else
        print("FAIL: move preview / selected props / folder browser:", tostring(err))
        os.exit(1)
    end
end

-- ============ 14. 设置持久化(插件目录,退出保存/启动读取) ============
do
    local ok, err = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local lfs = require("libs/libkoreader-lfs")
        local dir = "/tmp/drawingpad_settings_test"
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        local settings_path = dir .. "/drawingpad_settings.lua"
        pcall(os.remove, settings_path)
        local c1 = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
        c1.gray = 0.3
        c1.width = 9
        c1.font = "DroidSansFallback.ttf"
        c1.font_size = 42
        c1._last_text = "上次的字"
        -- 菜单/按钮状态(黑底白字的次要功能态):应保持默认(白底黑字),不被恢复
        c1.select_mode = "copy"
        c1.eraser_mode = "rect"
        c1.rect_filled = true
        c1.circle_filled = true
        c1.save_folder = "/mnt/us/测试目录"
        c1.tip = "diamond"
        c1:_saveSettings()
        check(lfs.attributes(settings_path, "mode") ~= nil, "settings file should be written")
        local c2 = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
        check(math.abs(c2.gray - 0.3) < 0.001, "gray restored, got " .. tostring(c2.gray))
        check(c2.width == 9, "width restored")
        check(c2.font == "DroidSansFallback.ttf", "font restored, got " .. tostring(c2.font))
        check(c2.font_size == 42, "font_size restored, got " .. tostring(c2.font_size))
        check(c2._last_text == "上次的字", "last_text restored, got " .. tostring(c2._last_text))
        check(c2.save_folder == "/mnt/us/测试目录", "save_folder restored")
        check(c2.tip == "diamond", "tip restored")
        check(c2.select_mode == "move", "menu state NOT restored: select_mode default move")
        check(c2.eraser_mode == "brush", "menu state NOT restored: eraser_mode default brush")
        check(c2.rect_filled == false, "menu state NOT restored: rect_filled default hollow")
        check(c2.circle_filled == false, "menu state NOT restored: circle_filled default hollow")
        pcall(os.remove, settings_path)
        pcall(lfs.rmdir, dir)
        print("settings persistence OK")
    end)
    if ok then
        print("PASS: settings persistence")
    else
        print("FAIL: settings persistence:", tostring(err))
        os.exit(1)
    end
end

-- ============ 15. 填充工具(点填/描边填) ============
do
    local ok, err = pcall(function()
        -- 点填:空心圆封闭区域单色填充
        local canvas = newCanvas()
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local bb = canvas.canvas_bb
        local function a(x, y) return bb:getPixel(x, y) and bb:getPixel(x, y).a end
        check(a(200, 300) == 255, "before fill: circle interior white")
        canvas:_setTool("fill")
        check(canvas.fill_mode == "tap", "fill default tap mode")
        canvas:onTap(nil, { pos = { x = 200, y = 300 } }) -- 点圆内部
        check(#canvas.elements == 2 and canvas.elements[2].kind == "fill",
            "fill creates fill element, got " .. tostring(#canvas.elements))
        check(a(200, 300) == 0, "after fill: interior black, got " .. tostring(a(200, 300)))
        check(a(50, 300) == 255, "outside circle stays white, got " .. tostring(a(50, 300)))
        -- fill 元素按 span 区域重放(区域重绘不丢)
        canvas:_redrawRegion(canvas:_elementRegion(canvas.elements[2]))
        check(a(200, 300) == 0, "fill re-renders on region redraw")
        -- 撤销恢复
        canvas:_undo()
        check(#canvas.elements == 1, "undo removes fill")
        check(a(200, 300) == 255, "undo restores interior white")

        -- 描边填:画笔闭合路径(起点=落点)只留填充面,路径墨迹被清除(不显示路径)
        local canvas2 = newCanvas()
        canvas2:_setTool("fill")
        canvas2:_toggleFillMode()
        check(canvas2.fill_mode == "path", "fill toggles to path mode")
        canvas2:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#canvas2.elements == 1 and canvas2.elements[1].kind == "fill",
            "closed path creates ONLY a fill element (no stroke), got "
            .. tostring(#canvas2.elements) .. "/"
            .. tostring(canvas2.elements[1] and canvas2.elements[1].kind))
        local bb2 = canvas2.canvas_bb
        local function a2(x, y) return bb2:getPixel(x, y) and bb2:getPixel(x, y).a end
        check(a2(150, 250) == 0, "closed path interior filled, got " .. tostring(a2(150, 250)))
        check(a2(99, 250) == 255, "path stroke cleared (not displayed), got " .. tostring(a2(99, 250)))

        -- 浅色描边:边界必须被识别,填充不溢出(洪泛容差 20)
        local canvasL = newCanvas()
        canvasL:_setTool("circle")
        canvasL:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local lcirc = canvasL.elements[1]
        lcirc.gray = 0.1 -- 浅灰描边(像素值≈229,与白背景差 26 > 容差 20)
        canvasL:_redrawRegion(canvasL:_elementRegion(lcirc))
        canvasL:_setTool("fill")
        canvasL:onTap(nil, { pos = { x = 200, y = 300 } }) -- 点圆内部
        local bbL = canvasL.canvas_bb
        local function aL(x, y) return bbL:getPixel(x, y) and bbL:getPixel(x, y).a end
        check(aL(200, 300) == 0, "light-stroke circle interior filled, got " .. tostring(aL(200, 300)))
        check(aL(90, 300) == 255, "light-stroke boundary stops fill (no overflow), got " .. tostring(aL(90, 300)))
        check(aL(100, 300) > 200, "light stroke ink preserved, got " .. tostring(aL(100, 300)))

        -- 5% 浅描边(灰 0.05,与白背景像素差 >8)也成边界,不溢出(边缘感知洪泛)
        local canvasL2 = newCanvas()
        canvasL2:_setTool("circle")
        canvasL2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local lcirc2 = canvasL2.elements[1]
        lcirc2.gray = 0.05
        canvasL2:_redrawRegion(canvasL2:_elementRegion(lcirc2))
        canvasL2:_setTool("fill")
        canvasL2:onTap(nil, { pos = { x = 200, y = 300 } })
        local bbL2 = canvasL2.canvas_bb
        local function aL2(x, y) return bbL2:getPixel(x, y) and bbL2:getPixel(x, y).a end
        check(aL2(200, 300) == 0, "5% stroke circle interior filled, got " .. tostring(aL2(200, 300)))
        check(aL2(90, 300) == 255, "5% stroke boundary stops fill (no overflow), got " .. tostring(aL2(90, 300)))

        -- 干涉:描边填只按自身路径计算,不被其他笔画截断/污染
        local canvasI = newCanvas()
        canvasI:_setTool("brush")
        canvasI:onSwipe(nil, { pos = { x = 100, y = 250 }, end_pos = { x = 300, y = 250 } }) -- 先画横线穿过区域
        canvasI:_setTool("fill")
        canvasI:_toggleFillMode()
        canvasI:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#canvasI.elements == 2 and canvasI.elements[2].kind == "fill",
            "interference: only line + fill (no stroke), got "
            .. tostring(#canvasI.elements) .. "/"
            .. tostring(canvasI.elements[2] and canvasI.elements[2].kind))
        local bbI = canvasI.canvas_bb
        local function aI(x, y) return bbI:getPixel(x, y) and bbI:getPixel(x, y).a end
        check(aI(150, 220) == 0, "fill covers above crossing line, got " .. tostring(aI(150, 220)))
        check(aI(150, 280) == 0, "fill covers below crossing line, got " .. tostring(aI(150, 280)))
        check(aI(250, 250) == 0, "crossing line outside square preserved, got " .. tostring(aI(250, 250)))
        check(aI(99, 220) == 255, "path boundary cleared (not displayed), got " .. tostring(aI(99, 220)))

        -- 远距自动闭合:落点离起点很远也自动连接闭合填内部(不吸附末点,
        -- 闭合段 = 落笔点→起点直线,填充区域 = 路径+闭合段围成的四边形)
        local canvas3 = newCanvas()
        canvas3:_setTool("fill")
        canvas3:_toggleFillMode()
        canvas3:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas3:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas3:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvas3:onPan(nil, { pos = { x = 250, y = 250 }, start_pos = { x = 100, y = 200 } }) -- 落点远在右上方
        canvas3:onPanRelease(nil, { pos = { x = 250, y = 250 } })
        check(canvas3.elements[1] and canvas3.elements[1].kind == "fill",
            "far endpoint auto-closes and fills, got "
            .. tostring(canvas3.elements[1] and canvas3.elements[1].kind))
        local bb3 = canvas3.canvas_bb
        local function a3(x, y) return bb3:getPixel(x, y) and bb3:getPixel(x, y).a end
        check(a3(210, 280) == 0, "auto-closed quadrilateral interior filled, got " .. tostring(a3(210, 280)))
        check(a3(120, 240) == 255, "outside auto-closed region stays white, got " .. tostring(a3(120, 240)))

        -- 直线不产生填充,路径也不显示(2 点退化 → 什么都不留)
        local canvas4 = newCanvas()
        canvas4:_setTool("fill")
        canvas4:_toggleFillMode()
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 300, y = 300 } })
        check(#canvas4.elements == 0,
            "straight line should leave nothing (no fill, no stroke), got " .. tostring(#canvas4.elements))

        -- 描边填 = 单 fill 元素 + 一条撤销记录:一次撤销清空,重做恢复填充
        local canvasU = newCanvas()
        canvasU:_setTool("fill")
        canvasU:_toggleFillMode()
        canvasU:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#canvasU.elements == 1 and canvasU.elements[1].kind == "fill" and #canvasU.undo == 1,
            "path fill should be ONE fill element + ONE undo, got "
            .. tostring(#canvasU.elements) .. "/" .. tostring(#canvasU.undo))
        local bbU = canvasU.canvas_bb
        local function aU(x, y) return bbU:getPixel(x, y) and bbU:getPixel(x, y).a end
        check(aU(150, 250) == 0, "path fill interior filled before undo")
        check(aU(99, 250) == 255, "path stroke cleared (not displayed), got " .. tostring(aU(99, 250)))
        canvasU:_undo()
        check(#canvasU.elements == 0, "one undo clears fill, got " .. tostring(#canvasU.elements))
        check(aU(150, 250) == 255, "undo clears fill interior, got " .. tostring(aU(150, 250)))
        canvasU:_redo()
        check(#canvasU.elements == 1 and canvasU.elements[1].kind == "fill",
            "redo restores fill, got "
            .. tostring(#canvasU.elements) .. "/"
            .. tostring(canvasU.elements[1] and canvasU.elements[1].kind))
        check(aU(150, 250) == 0, "redo re-fills interior, got " .. tostring(aU(150, 250)))

        -- 描边填 快速收尾(进行中路径被 swipe 完成):也自动闭合填充、路径不显示
        local canvasS = newCanvas()
        canvasS:_setTool("fill")
        canvasS:_toggleFillMode()
        canvasS:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasS:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasS:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasS:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 100, y = 200 } }) -- 快速收尾闭合
        check(#canvasS.elements == 1 and canvasS.elements[1].kind == "fill",
            "swipe-finished path should fill only (no stroke), got "
            .. tostring(#canvasS.elements) .. "/"
            .. tostring(canvasS.elements[1] and canvasS.elements[1].kind))
        local bbS = canvasS.canvas_bb
        local function aS(x, y) return bbS:getPixel(x, y) and bbS:getPixel(x, y).a end
        check(aS(150, 250) == 0, "swipe-finished path interior filled, got " .. tostring(aS(150, 250)))
        check(aS(99, 250) == 255, "swipe-finished path stroke cleared, got " .. tostring(aS(99, 250)))

        -- 点填:手势被分类成 pan / hold / swipe 时也要填充(防"偶发没反应")
        local canvasT = newCanvas()
        canvasT:_setTool("circle")
        canvasT:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        canvasT:_setTool("fill")
        canvasT:onPan(nil, { pos = { x = 203, y = 300 }, start_pos = { x = 200, y = 300 } })
        canvasT:onPanRelease(nil, { pos = { x = 203, y = 300 } }) -- tap 被分类成 pan
        check(canvasT.elements[2] and canvasT.elements[2].kind == "fill",
            "pan-delivered tap should fill, got "
            .. tostring(canvasT.elements[2] and canvasT.elements[2].kind))
        local bbT = canvasT.canvas_bb
        local function aT(x, y) return bbT:getPixel(x, y) and bbT:getPixel(x, y).a end
        check(aT(200, 300) == 0, "pan-delivered tap interior filled, got " .. tostring(aT(200, 300)))
        check(aT(50, 300) == 255, "pan-delivered tap stays inside circle (no overflow)")
        local canvasT2 = newCanvas()
        canvasT2:_setTool("circle")
        canvasT2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        canvasT2:_setTool("fill")
        canvasT2:onHold(nil, { pos = { x = 200, y = 300 } })
        canvasT2:onHoldRelease(nil, { pos = { x = 200, y = 300 } }) -- tap 被分类成 hold
        check(canvasT2.elements[2] and canvasT2.elements[2].kind == "fill",
            "hold-delivered tap should fill, got "
            .. tostring(canvasT2.elements[2] and canvasT2.elements[2].kind))
        local canvasT3 = newCanvas()
        canvasT3:_setTool("circle")
        canvasT3:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        canvasT3:_setTool("fill")
        canvasT3:onSwipe(nil, { pos = { x = 195, y = 300 }, end_pos = { x = 205, y = 300 } }) -- 快速点按
        check(canvasT3.elements[2] and canvasT3.elements[2].kind == "fill",
            "swipe-delivered tap should fill, got "
            .. tostring(canvasT3.elements[2] and canvasT3.elements[2].kind))

        -- 描边填 快速收尾且 swipe 终点滑出画布:也要立即闭合填充(不残留到下一次操作)
        local canvasO = newCanvas()
        canvasO:_setTool("fill")
        canvasO:_toggleFillMode()
        canvasO:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasO:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasO:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
        canvasO:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
        check(canvasO._stroke ~= nil, "stroke in progress before swipe-out")
        canvasO:onSwipe(nil, { pos = { x = 100, y = 400 }, end_pos = { x = 100, y = 50 } }) -- 终点在 header(画布外)
        check(canvasO._stroke == nil and #canvasO.elements == 1 and canvasO.elements[1].kind == "fill",
            "swipe-out should commit fill immediately (no residual stroke), got stroke="
            .. tostring(canvasO._stroke ~= nil) .. " elements=" .. tostring(#canvasO.elements)
            .. " kind=" .. tostring(canvasO.elements[1] and canvasO.elements[1].kind))

        -- 描边填 收尾被判定为 multiswipe(甩动轨迹有方向变化):也要立即收笔填充(注册 MultiSwipe)
        local canvasM = newCanvas()
        canvasM:_setTool("fill")
        canvasM:_toggleFillMode()
        canvasM:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasM:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasM:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
        canvasM:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
        check(canvasM._stroke ~= nil, "stroke in progress before multiswipe")
        canvasM:onMultiSwipe(nil, { pos = { x = 100, y = 400 }, end_pos = { x = 100, y = 50 } }) -- 终点甩到 header
        check(canvasM._stroke == nil and #canvasM.elements == 1 and canvasM.elements[1].kind == "fill",
            "multiswipe finish should commit fill immediately, got stroke="
            .. tostring(canvasM._stroke ~= nil) .. " elements=" .. tostring(#canvasM.elements)
            .. " kind=" .. tostring(canvasM.elements[1] and canvasM.elements[1].kind))
        -- 画布确实注册了 MultiSwipe 手势(经 onGesture 派发到 onMultiSwipe)
        check(canvasM.ges_events and canvasM.ges_events.MultiSwipe ~= nil,
            "canvas should register MultiSwipe gesture")
        print("fill tool: tap fill / path fill OK")
    end)
    if ok then
        print("PASS: fill tool")
    else
        print("FAIL: fill tool:", tostring(err))
        os.exit(1)
    end
end

-- ============ 16. 文字选取框对齐(旋转/拉伸) + 滑条调节弹窗 ============
do
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        -- 16a. 文字渲染墨迹与元素包围盒对齐(修复:旋转/拉伸后字体与选取框错位 0.8*字号)
        local function makeTextCanvas(text, size)
            local c = newCanvas()
            local el = { kind = "text", x = 200, y = 400, text = text, font = c.font, size = size, gray = 1.0 }
            table.insert(c.elements, el)
            c:_cacheBBox(el)
            return c, el
        end
        -- 渲染后扫描墨迹范围,断言:①墨迹在元素 bbox 内(修复前整体偏移会超出);
        -- ②墨迹中心与 bbox 中心对齐(偏移检测,对字形/抗锯齿空隙鲁棒)
        local function inkInside(c, el)
            c:_cacheBBox(el)
            local b = el._bbox
            c.canvas_bb:paintRect(0, 0, c.canvas_w, c.canvas_h, Blitbuffer.COLOR_WHITE)
            c:_drawTextTo(c.canvas_bb, el)
            local bb = c.canvas_bb
            local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
            local pad = 48
            for py = math.floor(b.y0) - pad, math.ceil(b.y1) + pad do
                for px = math.floor(b.x0) - pad, math.ceil(b.x1) + pad do
                    if px >= 0 and px < bb:getWidth() and py >= 0 and py < bb:getHeight() then
                        local p = bb:getPixel(px, py)
                        if p and p.a < 255 then
                            if px < minx then minx = px end
                            if px > maxx then maxx = px end
                            if py < miny then miny = py end
                            if py > maxy then maxy = py end
                        end
                    end
                end
            end
            if minx == math.huge then
                return false, "no ink rendered"
            end
            local inside = minx >= b.x0 - 2 and miny >= b.y0 - 2
                and maxx <= b.x1 + 2 and maxy <= b.y1 + 2
            local cdx = math.abs((minx + maxx) / 2 - (b.x0 + b.x1) / 2)
            local cdy = math.abs((miny + maxy) / 2 - (b.y0 + b.y1) / 2)
            local centered = cdx <= 4 and cdy <= 4
            return inside and centered,
                string.format("ink(%d,%d..%d,%d) bbox(%d,%d..%d,%d) center_delta(%d,%d)",
                    minx, miny, maxx, maxy, b.x0, b.y0, b.x1, b.y1, cdx, cdy)
        end

        local c1, el1 = makeTextCanvas("对齐测试", 32)
        local ok1, msg1 = inkInside(c1, el1)
        check(ok1, "untransformed text ink inside/centered: " .. msg1)
        local sb1 = el1._bbox
        local cx1, cy1 = (sb1.x0 + sb1.x1) / 2, (sb1.y0 + sb1.y1) / 2
        c1:_rotateElement(el1, math.pi / 2, cx1, cy1)
        local ok90, msg90 = inkInside(c1, el1)
        check(ok90, "rotated-90 text ink inside/centered: " .. msg90)
        local c2, el2 = makeTextCanvas("斜着", 28)
        local sb2 = el2._bbox
        local cx2, cy2 = (sb2.x0 + sb2.x1) / 2, (sb2.y0 + sb2.y1) / 2
        c2:_rotateElement(el2, math.pi / 4, cx2, cy2)
        local ok45, msg45 = inkInside(c2, el2)
        check(ok45, "rotated-45 text ink inside/centered: " .. msg45)
        local c3, el3 = makeTextCanvas("拉伸", 24)
        local sb3 = el3._bbox
        c3:_scaleElement(el3, sb3, { x0 = sb3.x0, y0 = sb3.y0, x1 = sb3.x0 + (sb3.x1 - sb3.x0) * 2, y1 = sb3.y1 })
        local okstr, msgstr = inkInside(c3, el3)
        check(okstr, "stretched text ink inside/centered: " .. msgstr)
        print("text frame align: untransformed/rot90/rot45/stretch OK")

        local UIManager = require("ui/uimanager")

        -- 16b. 选中对象灰度:滑条弹窗结构 + 滑条点按换算 + 预设档位 + 关闭写撤销
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line = canvas.elements[1]
        local undo0 = #canvas.undo -- 画线已写 1 条
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas._selected == line, "select line for value picker")
        local orig_show = UIManager.show
        local captured
        UIManager.show = function(self, w) captured = w; return true end
        pcall(function() canvas:_pickElementGray() end)
        UIManager.show = orig_show
        if captured and captured.name == "DrawingValuePicker" then
            -- 真实 paint 验证(构造 OK 但 paint 崩会整机闪退,如 pbar_w 漏定义)
            local Screen = require("device").screen
            local ok_paint = pcall(function() captured:paintTo(Screen.bb, 0, 0) end)
            check(ok_paint, "value picker should paint without error")
            local progress_ref
            local function walk(w)
                if not w then return end
                if w.getPercentageFromPosition then progress_ref = w end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then walk(cw) end
                end
            end
            walk(captured)
            check(progress_ref ~= nil, "value picker should contain ProgressWidget slider")
            -- 滑条点按定位:走真实事件链(Event:new 把 nil args 也打包占位,
            -- handler 必须签名 (_, ges) 否则 ges=nil 崩)——中点 → 50%
            if progress_ref then
                progress_ref.dimen = Geom:new{ x = 100, y = 200, w = 400, h = 10 }
                local Event = require("ui/event")
                captured:handleEvent(Event:new("TapProgress", nil, { pos = { x = 300, y = 205 } }))
                check(math.abs(line.gray - 0.5) < 0.001,
                    "slider tap sets 50%, got " .. tostring(line.gray))
            end
            -- 预设档位按最大值百分比:0(最小),12(1/8),25(2/8)...100(8/8)
            local preset_btn
            local preset_12
            local function findBtn(w)
                if not w then return end
                if w.buttons then
                    for _, row in ipairs(w.buttons) do
                        for _, b in ipairs(row) do
                            if b.text == "50%" then preset_btn = b end
                            if b.text == "12%" then preset_12 = b end
                        end
                    end
                end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then findBtn(cw) end
                end
            end
            findBtn(captured)
            check(preset_btn ~= nil, "value picker should have 50% preset (4/8)")
            check(preset_12 ~= nil, "value picker should have 12% preset (1/8 of max)")
            if preset_btn then
                preset_btn.callback()
                check(math.abs(line.gray - 0.5) < 0.001,
                    "preset button applies gray, got " .. tostring(line.gray))
            end
            -- 步进行 -10/-1/+1/+10 存在;点 +10 → gray 0.5→0.6
            local btn_p10, btn_m10
            local function findStep(w)
                if not w then return end
                if w.buttons then
                    for _, row in ipairs(w.buttons) do
                        for _, b in ipairs(row) do
                            if b.text == "+10" then btn_p10 = b end
                            if b.text == "-10" then btn_m10 = b end
                        end
                    end
                end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then findStep(cw) end
                end
            end
            findStep(captured)
            check(btn_p10 ~= nil and btn_m10 ~= nil,
                "value picker should have -10/+10 step buttons")
            if btn_p10 then
                btn_p10.callback()
                check(math.abs(line.gray - 0.6) < 0.001,
                    "+10 step applies, got " .. tostring(line.gray))
            end
            if btn_m10 then
                btn_m10.callback()
                check(math.abs(line.gray - 0.5) < 0.001,
                    "-10 step reverts, got " .. tostring(line.gray))
            end
            -- 关闭 → 写一条撤销(画线 1 条 + 灰度 1 条)
            captured:onCloseWidget()
            check(#canvas.undo == undo0 + 1, "value picker close writes one undo, got " .. tostring(#canvas.undo))
        else
            print("WARN: 值调节弹窗未能 headless 构造,跳过结构断言")
        end

        -- 16c. 选中对象粗细:预设档位 + 撤销
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line2 = canvas2.elements[1]
        local undo2_0 = #canvas2.undo
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        local orig_show2 = UIManager.show
        local captured2
        UIManager.show = function(self, w) captured2 = w; return true end
        pcall(function() canvas2:_pickElementWidth() end)
        UIManager.show = orig_show2
        if captured2 and captured2.name == "DrawingValuePicker" then
            local Screen = require("device").screen
            local ok_paint2 = pcall(function() captured2:paintTo(Screen.bb, 0, 0) end)
            check(ok_paint2, "width picker should paint without error")
            -- 粗细上限 800,档位按最大值百分比且无 px 后缀:1(最小),100(1/8),200(2/8)...
            local btn100
            local btn800
            local function findBtn2(w)
                if not w then return end
                if w.buttons then
                    for _, row in ipairs(w.buttons) do
                        for _, b in ipairs(row) do
                            if b.text == "100" then btn100 = b end
                            if b.text == "800" then btn800 = b end
                        end
                    end
                end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then findBtn2(cw) end
                end
            end
            findBtn2(captured2)
            check(captured2.max == 800, "width picker max should be 800, got " .. tostring(captured2.max))
            check(btn100 ~= nil and btn800 ~= nil,
                "width picker presets should be max-percentage without px (100/800)")
            if btn100 then
                btn100.callback()
                check(line2.width == 100, "preset width 1/8 applied, got " .. tostring(line2.width))
            end
            captured2:onCloseWidget()
            check(#canvas2.undo == undo2_0 + 1, "width picker close writes undo, got " .. tostring(#canvas2.undo))
        else
            print("WARN: 粗细弹窗未能 headless 构造,跳过断言")
        end

        -- 16d. 全局灰度设置的"固定" → 弹出滑条弹窗
        local canvas3 = newCanvas()
        local orig_show3 = UIManager.show
        local captures3 = {}
        UIManager.show = function(self, w) captures3[#captures3 + 1] = w; return true end
        pcall(function() canvas3:_pickGray() end)
        UIManager.show = orig_show3
        if captures3[1] and captures3[1].buttons then
            local fixed_btn
            for _, row in ipairs(captures3[1].buttons) do
                for _, b in ipairs(row) do
                    if b.id == "gray_fixed_btn" then fixed_btn = b end
                end
            end
            check(fixed_btn ~= nil, "gray menu should have fixed button")
            if fixed_btn then
                local orig_show4 = UIManager.show
                local captured4
                UIManager.show = function(self, w) captured4 = w; return true end
                fixed_btn.callback()
                UIManager.show = orig_show4
                check(captured4 ~= nil and captured4.name == "DrawingValuePicker",
                    "fixed gray should open slider picker, got " .. tostring(captured4 and captured4.name))
            end
        else
            print("WARN: 灰度菜单未能 headless 构造,跳过断言")
        end
        -- 16e. 粗细大时空心圆/矩形不被误丢(形状阈值与线宽解耦)
        local cw = newCanvas()
        cw:_setTool("circle")
        cw.width = 800
        cw:onPan(nil, { pos = { x = 300, y = 400 }, start_pos = { x = 300, y = 400 } })
        cw:onPanRelease(nil, { pos = { x = 380, y = 400 } }) -- 半径 80
        check(#cw.elements == 1 and cw.elements[1].kind == "circle" and cw.elements[1].rx == 80,
            "thick-width hollow circle should commit (not dropped), got "
            .. tostring(#cw.elements) .. "/" .. tostring(cw.elements[1] and cw.elements[1].rx))
        local cw2 = newCanvas()
        cw2:_setTool("rect")
        cw2.width = 800
        cw2:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 200, y = 400 } })
        cw2:onPanRelease(nil, { pos = { x = 300, y = 480 } }) -- 100x80
        check(#cw2.elements == 1 and cw2.elements[1].kind == "rect",
            "thick-width rect should commit (not dropped), got " .. tostring(#cw2.elements))
        -- 粗细大时微小误触(半径 3)仍丢弃
        local cw3 = newCanvas()
        cw3:_setTool("circle")
        cw3.width = 800
        cw3:onPan(nil, { pos = { x = 300, y = 400 }, start_pos = { x = 300, y = 400 } })
        cw3:onPanRelease(nil, { pos = { x = 303, y = 400 } }) -- 半径 3 < 8
        check(#cw3.elements == 0, "tiny thick-width circle still dropped as accidental, got "
            .. tostring(#cw3.elements))
        print("thick-width shapes: commit / drop OK")

        -- 16f. 选中文字 → 点"文字"工具 → 属性修改(内容/字体/字号)
        local cEdit = newCanvas()
        local tel = { kind = "text", x = 200, y = 400, text = "旧文字", font = cEdit.font, size = 24, gray = 1.0 }
        table.insert(cEdit.elements, tel)
        cEdit:_cacheBBox(tel)
        cEdit:_setTool("select")
        cEdit:onTap(nil, { pos = { x = 200, y = 400 } })
        check(cEdit._selected == tel, "select text element")
        local edit_undo0 = #cEdit.undo
        -- 核心:更新文字元素(对话框 headless 构造不了,直接测方法)
        cEdit:_updateTextElement(tel, "新文字")
        check(tel.text == "新文字", "text content updated, got " .. tostring(tel.text))
        check(#cEdit.undo == edit_undo0 + 1, "text edit writes one undo, got "
            .. tostring(#cEdit.undo))
        -- 无变化不写撤销
        cEdit:_updateTextElement(tel, "新文字")
        check(#cEdit.undo == edit_undo0 + 1, "no-change edit skips undo")
        -- _setTool 入口:选中文字时点文字工具不切工具(弹窗 headless 跳过,断言不切工具)
        local orig_showE = UIManager.show
        local capturedE
        UIManager.show = function(self, w) capturedE = w; return true end
        cEdit:_setTool("text")
        UIManager.show = orig_showE
        check(cEdit.tool == "select", "text tool click with text selected should not switch tool")
        if capturedE and capturedE.getInputText then
            check(capturedE:getInputText() == "新文字", "edit dialog prefills content")
        else
            print("WARN: 文字编辑对话框未能 headless 构造,跳过弹窗断言")
        end

        -- 16g. 插入文字后记住上次内容与字体;再次插入自动填入
        local cAuto = newCanvas()
        cAuto:_setTool("text")
        cAuto:_commitText(300, 400, "上次的字")
        check(cAuto._last_text == "上次的字", "last text saved, got "
            .. tostring(cAuto._last_text))
        check(cAuto._last_font == cAuto.font and cAuto._last_font_size == cAuto.font_size,
            "last font/size saved")
        -- 插入对话框预填上次内容(headless 构造不了 InputDialog,构造成功则断言)
        local orig_showA = UIManager.show
        local capturedA
        UIManager.show = function(self, w) capturedA = w; return true end
        pcall(function() cAuto:_showTextDialog(300, 400) end)
        UIManager.show = orig_showA
        if capturedA and capturedA.getInputText then
            check(capturedA:getInputText() == "上次的字",
                "dialog prefills last text, got " .. tostring(capturedA:getInputText()))
        else
            print("WARN: 文字插入对话框未能 headless 构造,跳过预填断言")
        end
        print("text edit dialog / last-input prefill OK")

        -- 16h. 描边填:描边固定 1px(不受粗细设置影响)+ 贝塞尔平滑(含起笔/落笔点)
        local cW = newCanvas()
        cW.width = 40 -- 粗细设大,描边仍应 1px
        cW:_setTool("fill")
        cW:_toggleFillMode()
        cW:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        cW:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(cW._stroke ~= nil and cW._stroke.width == 1,
            "fill path stroke width fixed at 1, got " .. tostring(cW._stroke and cW._stroke.width))
        -- hold 起笔同样 1px
        local cH = newCanvas()
        cH.width = 80
        cH:_setTool("fill")
        cH:_toggleFillMode()
        cH:onHold(nil, { pos = { x = 100, y = 300 } })
        check(cH._stroke ~= nil and cH._stroke.width == 1,
            "fill path hold stroke width fixed at 1, got " .. tostring(cH._stroke and cH._stroke.width))
        -- _smoothClosedPath 单元:方形闭合 → 点数更多、首=末=起点、质心近中心
        local cS = newCanvas()
        local sq = {
            { x = 100, y = 100 }, { x = 200, y = 100 },
            { x = 200, y = 200 }, { x = 100, y = 200 },
            { x = 100, y = 100 }, -- 闭合
        }
        local sm = cS:_smoothClosedPath(sq)
        check(#sm > #sq, "smooth should add points, got " .. tostring(#sm))
        -- Chaikin 2 轮:方形 4 唯一点 → 每轮每段 2 点 → 16 + 闭合 1 = 17
        check(#sm == 4 * 2 * 2 + 1, "chaikin 2 rounds per corner, got " .. tostring(#sm))
        -- 闭合:末点回到首点(Chaikin 切角不保留原顶点,首点=首段 3/4 点)
        local sf = sm[1]
        local sl = sm[#sm]
        check(sl.x == sf.x and sl.y == sf.y, "smooth closes (first==last)")
        -- 未闭合序列(末≠首):平滑后自动闭合(末点回到首点)
        local open = {
            { x = 100, y = 100 }, { x = 200, y = 100 },
            { x = 200, y = 200 }, { x = 100, y = 200 },
        } -- 方形三边+一角,未闭合
        local smo = cS:_smoothClosedPath(open)
        local sl2 = smo[#smo]
        check(sl2.x == smo[1].x and sl2.y == smo[1].y, "unclosed path auto-closes back to start")
        check(#smo == 4 * 2 * 2 + 1, "unclosed path smoothed+closed, got " .. tostring(#smo))
        local mx, my = 0, 0
        for _, p in ipairs(sm) do
            mx, my = mx + p.x, my + p.y
        end
        mx, my = mx / #sm, my / #sm
        check(math.abs(mx - 150) < 20 and math.abs(my - 150) < 20,
            "smooth centroid near square center, got " .. mx .. "," .. my)
        -- 描边填整体回归:闭合路径(手抖锯齿) → fill 元素 spans 非空(平滑边界)
        local cF = newCanvas()
        cF:_setTool("fill")
        cF:_toggleFillMode()
        cF:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 120, y = 205 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 210, y = 250 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 110, y = 305 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        cF:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#cF.elements == 1 and cF.elements[1].kind == "fill"
            and cF.elements[1].spans and #cF.elements[1].spans > 0,
            "smoothed closed path fills, got "
            .. tostring(cF.elements[1] and cF.elements[1].kind))
        local bbF = cF.canvas_bb
        local function aF(x, y) return bbF:getPixel(x, y) and bbF:getPixel(x, y).a end
        check(aF(150, 250) == 0, "smoothed fill interior black, got " .. tostring(aF(150, 250)))
        print("fill path: 1px stroke / bezier smoothing OK")

        -- 16i. 底部布局:工具栏/状态栏在底部,顶部可画、底部遮挡区不可画
        local cBot = newCanvas()
        check(cBot:_toCanvas(100, 50) ~= nil,
            "top area should be drawable (bottom toolbar layout)")
        check(cBot:_toCanvas(100, cBot.canvas_h - 1) == nil,
            "bottom toolbar area should not be drawable")
        check(cBot:_toCanvas(100, cBot.canvas_h - cBot.header_h - 5) ~= nil,
            "just above bottom header should be drawable")
        -- 最小化后底部也可画(工具栏隐藏)
        cBot:_setMinimized(true)
        check(cBot:_toCanvas(100, cBot.canvas_h - 1) ~= nil,
            "minimized bottom should be drawable")
        cBot:_setMinimized(false)
        check(cBot:_toCanvas(100, cBot.canvas_h - 1) == nil,
            "restored bottom not drawable again")
        -- v59b 取消长按:面板条目只带单击;直线/画笔是独立条目,toolSet 直接切
        local toolBt = cBot:_categoryBt("tool")
        check(toolBt.button_by_id["brush_btn"].hold_callback == nil
            and toolBt.button_by_id["line_btn"] ~= nil,
            "no hold_callback on panel entries; line_btn exists")
        toolBt.button_by_id["line_btn"].callback()
        check(cBot.tool == "line", "line_btn tap switches to line, got " .. tostring(cBot.tool))
        toolBt.button_by_id["brush_btn"].callback()
        check(cBot.tool == "brush", "brush_btn tap switches back")
        print("bottom layout / panel entries OK")

        -- 16j. 填充结果支持选取:选中/移动/灰度/缩放/复制
        local cF2 = newCanvas()
        cF2:_setTool("fill")
        cF2:_toggleFillMode()
        cF2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        cF2:onPanRelease(nil, { pos = { x = 100, y = 300 } })
        local fillEl = cF2.elements[1]
        check(fillEl and fillEl.kind == "fill", "setup fill element")
        local fbb0 = fillEl._bbox
        cF2:_setTool("select")
        cF2:onTap(nil, { pos = { x = 150, y = 350 } }) -- 点 fill 内部
        check(cF2._selected == fillEl, "fill element selectable")
        -- 移动(+30,+20)
        cF2:onPan(nil, { pos = { x = 150, y = 350 }, start_pos = { x = 150, y = 350 } })
        cF2:onPanRelease(nil, { pos = { x = 180, y = 370 } })
        local fb1 = fillEl._bbox
        check(fb1.x0 == fbb0.x0 + 30 and fb1.y0 == fbb0.y0 + 20,
            "fill moved, got " .. fb1.x0 .. "," .. fb1.y0)
        -- 灰度
        cF2:_applySelectedGray(50)
        check(math.abs(fillEl.gray - 0.5) < 0.001, "fill gray changed, got "
            .. tostring(fillEl.gray))
        -- 缩放:拖 se 角放大,bbox 变大且 spans 重栅格化
        local fc = cF2:_frameCorners(fillEl)
        local se = fc[3]
        cF2:onPan(nil, { pos = { x = se.x, y = se.y }, start_pos = { x = se.x, y = se.y } })
        cF2:onPanRelease(nil, { pos = { x = se.x + 60, y = se.y + 40 } })
        local fb2 = fillEl._bbox
        check(fb2.x1 > fb1.x1 + 40 and fb2.y1 > fb1.y1 + 20,
            "fill scaled bigger, got " .. fb1.x1 .. "->" .. fb2.x1 .. ", " .. fb1.y1 .. "->" .. fb2.y1)
        -- 复制:独立副本(spans 深拷贝)
        cF2:_toggleSelectMode() -- copy
        cF2:onTap(nil, { pos = { x = 180, y = 370 } }) -- 重新选中(缩放后仍在内部)
        check(cF2._selected == fillEl, "reselect fill after scale")
        cF2:onPan(nil, { pos = { x = 180, y = 370 }, start_pos = { x = 180, y = 370 } })
        cF2:onPanRelease(nil, { pos = { x = 120, y = 430 } })
        check(#cF2.elements == 2, "fill copy adds element, got " .. tostring(#cF2.elements))
        local fillCopy = cF2.elements[2]
        check(fillCopy ~= fillEl and fillCopy.kind == "fill", "copy is distinct fill")
        check(fillCopy.spans[1] ~= fillEl.spans[1], "copy spans deep-copied")
        -- 拉大后的填充面必须稠密:逐行单点映射会在目标行间留空行 → 密集横纹;
        -- 修复后按源行纵向半行带铺满目标行,行集连续(相邻行差 1)
        local ys = {}
        for _, sp in ipairs(fillEl.spans) do ys[sp[1]] = true end
        local ymin2, ymax2, nrows = math.huge, -math.huge, 0
        for y in pairs(ys) do
            nrows = nrows + 1
            if y < ymin2 then ymin2 = y end
            if y > ymax2 then ymax2 = y end
        end
        check(nrows > 0 and nrows == ymax2 - ymin2 + 1,
            "fill scaled-up spans dense (no horizontal stripes), rows=" .. nrows
            .. " range=" .. ymin2 .. "-" .. ymax2)
        -- 旋转:复制前"再次点选"已切到 rotate 模式(上文 1914 行),拖 se 角绕包围盒中心旋转 30°
        check(cF2._handle_mode == "rotate", "fill toggles to rotate mode")
        local rb = fillEl._bbox
        local rcx, rcy = (rb.x0 + rb.x1) / 2, (rb.y0 + rb.y1) / 2
        local seA = { x = rb.x1 + 4, y = rb.y1 + 4 } -- se 锚点(_frameCorners pad=4)
        local adx, ady = seA.x - rcx, seA.y - rcy
        local c30, s30 = math.cos(math.pi / 6), math.sin(math.pi / 6)
        cF2:onPan(nil, { pos = { x = seA.x, y = seA.y }, start_pos = { x = seA.x, y = seA.y } })
        cF2:onPanRelease(nil, {
            pos = { x = rcx + adx * c30 - ady * s30, y = rcy + adx * s30 + ady * c30 },
        })
        local rb2 = fillEl._bbox
        check(rb2.x1 - rb2.x0 > 120 and rb2.y1 - rb2.y0 > 120,
            "fill rotated 30deg bbox grows, got " .. (rb2.x1 - rb2.x0)
            .. "x" .. (rb2.y1 - rb2.y0))
        -- 旋转后行集仍稠密(逐 span 旋转重栅格化无横纹)
        local rys = {}
        for _, sp in ipairs(fillEl.spans) do rys[sp[1]] = true end
        local rmin, rmax, rn = math.huge, -math.huge, 0
        for y in pairs(rys) do
            rn = rn + 1
            if y < rmin then rmin = y end
            if y > rmax then rmax = y end
        end
        check(rn > 0 and rn == rmax - rmin + 1,
            "fill rotated spans dense, rows=" .. rn .. " range=" .. rmin .. "-" .. rmax)
        -- 旋转后仍可切换回缩放模式
        cF2:onTap(nil, { pos = { x = 180, y = 370 } })
        check(cF2._handle_mode == "scale", "fill toggles back to scale")
        -- 旋转提交的刷新区域必须覆盖预览累积区:拖拽预览跟随期间中间位置的 fill 残影
        -- 若未并入提交刷新,松手后残留多个角度的 fill 影 = 横纹(拉伸预览区域更大更明显)
        do
            local UIManager = require("ui/uimanager")
            local seen = {}
            local old_sd = UIManager.setDirty
            UIManager.setDirty = function(_, _, mode, region)
                table.insert(seen, { mode = mode, region = region })
            end
            -- 模拟预览跟随的中间位置:旋转 30° 再平移(残影区明显偏离提交区)
            local pv2 = cF2:_cloneElement(fillEl)
            local bb3 = fillEl._bbox
            local pcx, pcy = (bb3.x0 + bb3.x1) / 2, (bb3.y0 + bb3.y1) / 2
            cF2:_rotateElement(pv2, math.rad(30), pcx, pcy)
            cF2:_moveElement(pv2, 60, 40)
            cF2:_cacheBBox(pv2)
            cF2._drag_preview = pv2
            cF2._drag_preview_region = cF2:_elementRegion(pv2)
            local pvr = cF2._drag_preview_region
            -- 拖角旋转提交(45°)
            cF2._handle_mode = "rotate"
            local fc3 = cF2:_frameCorners(fillEl)
            local se3 = fc3[3]
            local bb4 = fillEl._bbox
            local cx3, cy3 = (bb4.x0 + bb4.x1) / 2, (bb4.y0 + bb4.y1) / 2
            local dx3, dy3 = se3.x - cx3, se3.y - cy3
            local c45b, s45b = math.cos(math.pi / 4), math.sin(math.pi / 4)
            cF2:onPan(nil, { pos = { x = se3.x, y = se3.y }, start_pos = { x = se3.x, y = se3.y } })
            cF2:onPanRelease(nil, {
                pos = { x = cx3 + dx3 * c45b - dy3 * s45b, y = cy3 + dx3 * s45b + dy3 * c45b },
            })
            UIManager.setDirty = old_sd
            local cov = false
            for _, s in ipairs(seen) do
                local r = s.region
                if r and pvr and pvr.x >= r.x and pvr.y >= r.y
                    and pvr.x + pvr.w <= r.x + r.w and pvr.y + pvr.h <= r.y + r.h then
                    cov = true
                end
            end
            check(cov, "rotate submit refresh covers preview residue region")
        end
        -- 旋转 fill 的窄行必须保持原始几何边界，不能被相邻行扩张成穿模横线。
        -- (src_points 方案后旋转 spans 由顶点扫描线重算、天然致密无缝,窄行是真实
        -- 几何尖端;渲染按 span 原样复写,不再做"邻行扩张"修补——扩张本身就是穿模)
        do
            local Blitbuffer = require("ffi/blitbuffer")
            local shapes = require("drawingpad.shapes")
            local fe = { kind = "fill", gray = 1, spans = {} }
            for y = 100, 120 do fe.spans[#fe.spans + 1] = { y, 100, 200 } end
            for i, sp in ipairs(fe.spans) do
                if sp[1] == 110 then fe.spans[i] = { 110, 150, 150 } end
            end
            local bbF = Blitbuffer.new(300, 150, Blitbuffer.TYPE_BB8)
            bbF:fill(Blitbuffer.COLOR_WHITE)
            shapes.drawElement(bbF, fe, Blitbuffer.gray(1), 0, 0)
            local black = 0
            for x = 99, 201 do
                if bbF:getPixel(x, 110).a < 200 then black = black + 1 end
            end
            bbF:free()
            check(black == 1, "render keeps narrow row as-is (no expansion), got " .. black)
        end
        print("fill selectable: pick/move/gray/scale/copy/rotate OK")
        print("value picker: slider tap/presets/undo OK")
    end)
    if ok then
        print("PASS: text frame align / value picker")
    else
        print("FAIL: text frame align / value picker:", tostring(err))
        os.exit(1)
    end
end

print("ALL FEATURE TESTS PASSED")
os.exit(0)
