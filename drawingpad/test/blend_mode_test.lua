--[[--
透明度混合模式(blend mode)单测:
1. shapes.blendModePixel 三模式公式(normal/multiply/dodge)
2. shapes.alphaProxy 带 mode:白底/叠墨/越界裁剪
3. 画布集成:multiply 两笔 50% 黑矩形重叠处比 normal 更深(叠墨互乘)
4. 混合模式随元素持久:画布切回 normal 后区域重绘,旧元素仍按 multiply 复现;
   新元素按 normal 混合
5. dodge:中灰 50% 叠在暗底上比 normal 提亮;黑墨 dodge 不改变底色
6. 透明度设置弹窗含混合模式键,点击循环 正常→正片叠底→线性减淡→正常
7. const.SETTING_KEYS 含 alpha_blend(退出持久化)

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/blend_mode_test.lua
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
local const = require("drawingpad.const")
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

-- 1. blendModePixel 公式
section("blendModePixel formulas", function()
    local bb = Blitbuffer.new(4, 4, Blitbuffer.TYPE_BB8)
    -- normal: out = d + a·(ink-d) —— d=100, ink=0, a=128 → ≈50
    bb:setPixel(0, 0, Blitbuffer.Color8(100))
    shapes.blendModePixel(bb, 0, 0, 0, 128, "normal")
    check(math.abs(px(bb, 0, 0) - 50) <= 1, "normal d100 ink0 a50% ~= 50, got " .. px(bb, 0, 0))
    -- multiply: out = d·(1-a·(255-ink)/255) —— d=64, ink=128, a=128 → 64·(1-0.25)=48
    bb:setPixel(1, 0, Blitbuffer.Color8(64))
    shapes.blendModePixel(bb, 1, 0, 128, 128, "multiply")
    check(math.abs(px(bb, 1, 0) - 48) <= 1, "multiply d64 ink128 a50% ~= 48, got " .. px(bb, 1, 0))
    -- dodge: out = (1-a)·d + a·min(255, ink+d) —— d=64, ink=128, a=128 → (64+192)/2=128
    bb:setPixel(2, 0, Blitbuffer.Color8(64))
    shapes.blendModePixel(bb, 2, 0, 128, 128, "dodge")
    check(math.abs(px(bb, 2, 0) - 128) <= 1, "dodge d64 ink128 a50% ~= 128, got " .. px(bb, 2, 0))
    -- dodge 黑墨不改底色:d=200, ink=0 → 200
    bb:setPixel(3, 0, Blitbuffer.Color8(200))
    shapes.blendModePixel(bb, 3, 0, 0, 128, "dodge")
    check(px(bb, 3, 0) == 200, "dodge black ink keeps dest, got " .. px(bb, 3, 0))
    -- 未知模式按 normal 处理(不崩)
    bb:setPixel(0, 1, Blitbuffer.Color8(100))
    shapes.blendModePixel(bb, 0, 1, 0, 128, "bogus")
    check(math.abs(px(bb, 0, 1) - 50) <= 1, "unknown mode falls back to normal, got " .. px(bb, 0, 1))
    bb:free()
end)

-- 1b. LUT 与 blendModePixel 公式 256 全值一致(快路等价性)
section("blend LUT matches blendModePixel for all dest", function()
    for _, mode in ipairs{ "normal", "multiply", "dodge" } do
        for _, ink in ipairs{ 0, 1, 64, 128, 254, 255 } do
            for _, a255 in ipairs{ 1, 32, 128, 200, 255 } do
                local lut = shapes.buildBlendLUT(mode, ink, a255)
                local bb = Blitbuffer.new(1, 1, Blitbuffer.TYPE_BB8)
                for d = 0, 255 do
                    bb:setPixel(0, 0, Blitbuffer.Color8(d))
                    shapes.blendModePixel(bb, 0, 0, ink, a255, mode)
                    local expect = px(bb, 0, 0)
                    if lut[d] ~= expect then
                        bb:free()
                        error(string.format("FAIL: LUT[%s ink=%d a=%d] d=%d lut=%s expect=%s",
                            mode, ink, a255, d, tostring(lut[d]), tostring(expect)))
                    end
                end
                bb:free()
            end
        end
    end
end)

-- 2. alphaProxy 带 mode
section("alphaProxy multiply/dodge over white & ink", function()
    local bb = Blitbuffer.new(30, 10, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, 30, 10, Blitbuffer.COLOR_WHITE)
    -- multiply 黑 50% 画白底 = 与 normal 相同(白是乘法单位元)
    local pm = shapes.alphaProxy(bb, 0.5, "multiply")
    pm:paintRect(0, 0, 10, 10, Blitbuffer.gray(1.0))
    check(math.abs(px(bb, 5, 5) - 128) <= 2, "multiply black 50% on white ~= 128, got " .. px(bb, 5, 5))
    -- multiply 中灰 50% 画白底 = (1-a)·255 + a·ink ≈ 191(乘法只在叠墨时体现差异)
    pm:paintRect(10, 0, 10, 10, Blitbuffer.gray(0.5))
    check(math.abs(px(bb, 15, 5) - 191) <= 2, "multiply midgray 50% on white ~= 191, got " .. px(bb, 15, 5))
    -- dodge 中灰 50% 画白底 = 白(128+255 截断 255,再与白混合仍白)
    local pd = shapes.alphaProxy(bb, 0.5, "dodge")
    pd:paintRect(20, 0, 10, 10, Blitbuffer.gray(0.5))
    check(px(bb, 25, 5) >= 253, "dodge midgray on white stays white, got " .. px(bb, 25, 5))
    -- 叠墨:multiply 中灰 50% 叠在 d=64 上 → 64·(1-0.5·127/255) ≈ 48(normal 会是 96)
    bb:paintRect(10, 0, 10, 10, Blitbuffer.Color8(64))
    pm:paintRect(10, 0, 10, 10, Blitbuffer.gray(0.5))
    check(math.abs(px(bb, 15, 5) - 48) <= 2, "multiply midgray over 64 ~= 48, got " .. px(bb, 15, 5))
    -- 越界裁剪安全(paintRect 原生裁剪后 setter 只收画布内坐标)
    local bb2 = Blitbuffer.new(10, 10, Blitbuffer.TYPE_BB8)
    bb2:paintRect(0, 0, 10, 10, Blitbuffer.COLOR_WHITE)
    local p2 = shapes.alphaProxy(bb2, 0.5, "multiply")
    p2:paintRect(-5, -5, 10, 10, Blitbuffer.gray(1.0))
    check(math.abs(px(bb2, 0, 0) - 128) <= 2, "clipped multiply blends in-canvas, got " .. px(bb2, 0, 0))
    check(px(bb2, 8, 8) >= 253, "clipped multiply leaves outside untouched, got " .. px(bb2, 8, 8))
    bb2:free()
    bb:free()
end)

-- 3. 画布集成:multiply 两笔 50% 黑矩形,重叠处 64(normal 下仍是 128)
section("canvas multiply rects overlap darker", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    canvas.alpha = 0.5
    canvas.alpha_blend = "multiply"
    canvas.gray = 1.0
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
    canvas:onPan(nil, { pos = { x = 150, y = 250 }, start_pos = { x = 150, y = 250 } })
    canvas:onPanRelease(nil, { pos = { x = 250, y = 350 } })
    check(#canvas.elements == 2, "two rects committed, got " .. #canvas.elements)
    check(canvas.elements[1].blend == "multiply", "blend recorded on element")
    local v_single = px(canvas.canvas_bb, 120, 220) -- 只在第一笔内
    local v_overlap = px(canvas.canvas_bb, 175, 275) -- 两笔重叠
    check(math.abs(v_single - 128) <= 2, "single rect ~128, got " .. v_single)
    check(math.abs(v_overlap - 64) <= 2, "multiply overlap ~64, got " .. v_overlap)
    canvas:onCloseWidget()
end)

-- 4. 混合模式随元素持久(重绘复现)+ 新元素按当前设置
section("blend persists per element across redraw", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    canvas.alpha = 0.5
    canvas.alpha_blend = "multiply"
    canvas.gray = 1.0
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
    local el = canvas.elements[1]
    -- 切回 normal,整区域白刷重绘:multiply 元素必须按原样复现(白底上仍 ~128)
    canvas.alpha_blend = "normal"
    local reg = canvas:_elementRegion(el)
    canvas:_redrawRegion(reg)
    local v = px(canvas.canvas_bb, 150, 250)
    check(math.abs(v - 128) <= 2, "multiply element reproduced after redraw, got " .. v)
    -- 新元素 normal 模式中灰 50% 叠在其上:out = 0.5·128 + 0.5·128 = 128;
    -- 若错误沿用 multiply 会是 64
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 130, y = 230 }, start_pos = { x = 130, y = 230 } })
    canvas:onPanRelease(nil, { pos = { x = 180, y = 280 } })
    check(canvas.elements[2].blend == "normal", "new element uses current mode")
    local v2 = px(canvas.canvas_bb, 155, 255)
    check(math.abs(v2 - 128) <= 2, "normal midgray over 128 stays ~128, got " .. v2)
    canvas:onCloseWidget()
end)

-- 5. dodge 提亮:multiple 暗底 d≈64 上中灰 50% → ≈128(normal 是 96)
section("canvas dodge lightens over dark ink", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    -- 底:不透明深灰 d≈64
    canvas.alpha = 1.0
    canvas.gray = 0.75
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
    -- 上:线性减淡 中灰 50%
    canvas.alpha = 0.5
    canvas.alpha_blend = "dodge"
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 120, y = 220 }, start_pos = { x = 120, y = 220 } })
    canvas:onPanRelease(nil, { pos = { x = 220, y = 320 } })
    local v = px(canvas.canvas_bb, 160, 260)
    check(math.abs(v - 128) <= 3, "dodge midgray 50% over d64 ~= 128, got " .. v)
    canvas:onCloseWidget()
end)

-- 6. 设置弹窗混合模式行:存在 + 循环切换
section("alpha dialog blend mode row cycles", function()
    local canvas = newCanvas()
    check(canvas.alpha_blend == "normal", "default blend is normal")
    local captured
    canvas._showCenteredButtons = function(_, title, btns, width)
        captured = btns
        return nil, nil
    end
    canvas:_pickAlpha()
    check(captured ~= nil, "dialog captured")
    check(#captured == 3, "alpha dialog has 3 rows, got " .. #captured)
    local mode_btn = captured[3][1]
    check(mode_btn.id == "alpha_blend_btn", "3rd row is blend button, got " .. tostring(mode_btn.id))
    local txt = mode_btn.text or ""
    check(txt:find("Blend") or txt:find("混合"), "blend button label, got " .. txt)
    mode_btn.callback()
    check(canvas.alpha_blend == "multiply", "cycle 1 -> multiply, got " .. tostring(canvas.alpha_blend))
    mode_btn.callback()
    check(canvas.alpha_blend == "dodge", "cycle 2 -> dodge, got " .. tostring(canvas.alpha_blend))
    mode_btn.callback()
    check(canvas.alpha_blend == "normal", "cycle 3 -> normal, got " .. tostring(canvas.alpha_blend))
    canvas:onCloseWidget()
end)

-- 7. 持久化键
section("SETTING_KEYS has alpha_blend", function()
    local found = false
    for _, k in ipairs(const.SETTING_KEYS) do
        if k == "alpha_blend" then
            found = true
            break
        end
    end
    check(found, "alpha_blend not in SETTING_KEYS")
end)

-- 7b. 粗斜线笔尖半透明不被裁(回归:tmp pad 只算 0.5w 时 slash 笔尖四角被切)
section("thick slash tip not clipped in alpha compositing", function()
    -- slash 笔尖半径 = 0.707w + 条带 t/2(max(2,w/3)) ≈ 0.87w;w=100 → 87px,
    -- 旧 pad(52px)会把超出部分裁掉 → 半透明墨迹 bbox 比近不透明小 30+px
    local function inkBBox(alpha)
        local bb = Blitbuffer.new(300, 300, Blitbuffer.TYPE_BB8)
        bb:paintRect(0, 0, 300, 300, Blitbuffer.COLOR_WHITE)
        local el = { kind = "freehand", points = { { x = 150, y = 150 } },
            width = 100, gray = 1.0, alpha = alpha, tip = "slash" }
        shapes.drawElement(shapes.alphaProxy(bb, alpha, "normal"), el, Blitbuffer.gray(el.gray))
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for yy = 0, 299 do
            for xx = 0, 299 do
                if px(bb, xx, yy) < 250 then
                    if xx < x0 then x0 = xx end
                    if xx > x1 then x1 = xx end
                    if yy < y0 then y0 = yy end
                    if yy > y1 then y1 = yy end
                end
            end
        end
        bb:free()
        return x0, y0, x1, y1
    end
    local ox0, oy0, ox1, oy1 = inkBBox(0.99) -- a255=252,仍走 tmp 单次合成,近不透明
    local ax0, ay0, ax1, ay1 = inkBBox(0.5)
    check(math.abs(ax0 - ox0) <= 2 and math.abs(ay0 - oy0) <= 2
        and math.abs(ax1 - ox1) <= 2 and math.abs(ay1 - oy1) <= 2,
        string.format("slash ink bbox: alpha0.99=(%d,%d,%d,%d) alpha0.5=(%d,%d,%d,%d)",
            ox0, oy0, ox1, oy1, ax0, ay0, ax1, ay1))
    -- 笔尖确实超出 0.5w pad(否则此测试测不到旧 bug)
    check(150 - ox0 > 60 and ox1 - 150 > 60 and 150 - oy0 > 60 and oy1 - 150 > 60,
        string.format("slash tip extends beyond 0.5w, got bbox (%d,%d,%d,%d)", ox0, oy0, ox1, oy1))
end)

-- 8. 透明度弹窗真实 paint(坑 14c:构造 OK 但 paint 崩的布局问题测不出来)
section("alpha dialog real paint with blend row", function()
    local canvas = newCanvas()
    local UIManager = require("ui/uimanager")
    local orig_show, orig_close = UIManager.show, UIManager.close
    UIManager.show = function() end
    UIManager.close = function() end
    local bt
    local orig_scb = canvas._showCenteredButtons
    canvas._showCenteredButtons = function(s, title, btns, wf)
        bt, canvas._dlg_popup = orig_scb(s, title, btns, wf)
        return bt, canvas._dlg_popup
    end
    local ok, err = pcall(function()
        canvas:_pickAlpha()
    end)
    UIManager.show, UIManager.close = orig_show, orig_close
    check(ok, "pickAlpha runs: " .. tostring(err))
    check(bt ~= nil, "real ButtonTable built")
    local n = 0
    for _ in pairs(bt.button_by_id or {}) do
        n = n + 1
    end
    check(n == 5, "alpha dialog has 5 id'd buttons (max/min/levels/fixed/blend), got " .. n)
    local Screen = require("device").screen
    local pok = pcall(function() bt:paintTo(Screen.bb, 0, 0) end)
    check(pok, "alpha dialog paints without crash")
    canvas:onCloseWidget()
end)

print(string.format("RESULT: %d passed", passed))
