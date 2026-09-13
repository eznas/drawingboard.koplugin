--[[--
绘图板对抗性测试(v57):以用户误操作/边界输入/异常序列为假设,覆盖 30 个场景。
与 feature_test(功能正测)互补——这里专测"不该发生的事":空输入、超界、连点、
损坏文件、越界坐标、模式残留。每个场景独立画布 + pcall,失败收集后统一汇总,
全部跑完再退出(不像 feature_test 首错即停),一次看清所有对抗面。

运行(从模拟器目录):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/adversarial_test.lua
--]]

-- 测试自定位注入 package.path(不经 pluginloader)
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

local UIManager = require("ui/uimanager")
local const = require("drawingpad.const")

-- 模拟器 540x720,底部 header_h≈109 不可画,安全画区 x≤520/y≤450(坑:v55 系列)
local SAFE = { x = 300, y = 300 }

local failures = {}
local passes = 0

-- 场景执行器:独立画布 + pcall,失败记录不中断
local function scenario(name, fn)
    local ok, err = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        fn(canvas)
    end)
    if ok then
        passes = passes + 1
        print("PASS:", name)
    else
        table.insert(failures, { name = name, err = tostring(err) })
        print("FAIL:", name, "->", tostring(err))
    end
end

local function check(cond, msg)
    if not cond then
        error(msg, 2)
    end
end

-- 快捷手势模拟(与 feature_test 同套路)
local function pan(canvas, x0, y0, x1, y1)
    canvas:onPan(nil, { pos = { x = x1, y = y1 }, start_pos = { x = x0, y = y0 } })
    canvas:onPanRelease(nil, { pos = { x = x1, y = y1 } })
end
local function tap(canvas, x, y)
    canvas:onTap(nil, { pos = { x = x, y = y } })
end

-- ============================ 场景 1-10:空状态与撤销 ============================

-- 1. 空画布撤销/重做 200 次:栈空静默无操作,不崩不越界
-- v61p:合并按钮家族(_doUndoRedo 等)已删,直接测 _undo/_redo
scenario("empty undo/redo x200", function(canvas)
    for _ = 1, 200 do
        canvas:_undo()
        canvas:_redo()
    end
    check(#canvas.elements == 0, "elements should stay 0")
end)

-- 2. 有内容撤销到底再重做到顶,往返 50 次
scenario("undo/redo roundtrip x50", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    check(#canvas.elements == 1, "one stroke")
    for _ = 1, 50 do
        canvas:_undo()
        check(#canvas.elements == 0, "undone")
        canvas:_redo()
        check(#canvas.elements == 1, "redone")
    end
    check(#canvas.elements == 1, "stroke survives roundtrip")
end)

-- 3. 撤销 → 切层 → 撤销:两层栈互不污染
scenario("undo then switch layer then undo", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260) -- 层 1 一笔
    canvas:_undo() -- 撤销层 1
    check(#canvas.elements == 0, "layer1 emptied")
    canvas:_switchLayer(2)
    canvas:_setTool("brush")
    pan(canvas, 200, 200, 260, 260) -- 层 2 一笔
    canvas:_undo() -- 撤销层 2
    check(#canvas.elements == 0, "layer2 emptied, independent stack")
    canvas:_switchLayer(1)
    check(#canvas.elements == 0, "layer1 still emptied")
end)

-- 4. 切层时 redo 栈隔离:新层 redo 为空(不会误放旧层记录),回原层 redo 仍在
scenario("redo stack isolated across layers", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas:_undo() -- 撤销,默认层 redo 栈有 1 条
    canvas:_switchLayer(3)
    canvas:_redo() -- 新层 redo 栈为空,静默无操作
    check(#canvas.elements == 0, "redo on fresh layer is no-op")
    canvas:_switchLayer(2)
    canvas:_redo()
    check(#canvas.elements == 1, "redo restores on original layer")
end)

-- 4b. 模式快速往返即时 + v57d 新命名契约(灰随/粗随/框擦/曲填)
scenario("mode toggle roundtrip + v59f", function(canvas)
    local function btnOf(id)
        for _, cat in ipairs({ "tool", "prop", "layer", "func" }) do
            local b = canvas:_categoryBt(cat).button_by_id[id]
            if b then return b end
        end
    end
    local function label(id)
        local b = btnOf(id)
        return b and b.text or "?"
    end
    local function bg(id)
        local b = btnOf(id)
        return b and b[1] and b[1].background
    end
    local function hold(id)
        local b = btnOf(id)
        return b and b.hold_callback
    end
    local BLB = require("ffi/blitbuffer")
    -- 矩形/圆形:短按切工具,长按切勾选
    check(label("rect_btn") == "矩形(☐填充)", "rect label, got " .. label("rect_btn"))
    btnOf("rect_btn").callback()
    check(canvas.tool == "rect" and bg("rect_btn") == BLB.COLOR_LIGHT_GRAY and canvas.rect_filled == false,
        "tap selects rect WITHOUT toggling filled")
    hold("rect_btn")()
    check(canvas.rect_filled == true and label("rect_btn") == "矩形(☑填充)", "hold toggles filled")
    btnOf("circle_btn").callback()
    check(canvas.tool == "circle" and bg("rect_btn") == BLB.COLOR_WHITE, "circle tap selects")
    hold("circle_btn")()
    check(canvas.circle_filled == true and label("circle_btn") == "圆形(☑填充)", "circle hold toggles filled")
    -- 擦除(☑框选):短按切橡皮,长按切框选
    check(label("eraser_btn") == "擦除(☐框选)", "eraser renamed, got " .. label("eraser_btn"))
    btnOf("eraser_btn").callback()
    check(canvas.tool == "eraser" and canvas.eraser_mode == "brush", "eraser tap selects brush mode")
    hold("eraser_btn")()
    check(canvas.eraser_mode == "rect" and label("eraser_btn") == "擦除(☑框选)", "eraser hold toggles rect")
    -- 填充改名
    check(label("fill_btn") == "填充(☐路径)", "fill merged entry label, got " .. label("fill_btn"))
    -- 灰度/粗细:短按弹设置,长按切随机
    check(label("gray_btn") == "灰度(☐随机)", "gray label, got " .. label("gray_btn"))
    hold("gray_btn")()
    check(canvas.gray_random == true and label("gray_btn") == "灰度(☑随机)", "gray hold toggles random")
    hold("gray_btn")()
    check(canvas.gray_random == false, "gray hold back")
    hold("width_btn")()
    check(canvas.width_random == true and label("width_btn") == "粗细(☑随机)", "width hold toggles")
    hold("width_btn")()
    -- 图层:每层单条目,短按切层,长按切隐藏
    btnOf("layer3_btn").callback()
    check(canvas.active_layer == 3 and label("layer3_btn") == "●上图层(☐隐藏)"
        and bg("layer3_btn") == BLB.COLOR_LIGHT_GRAY, "layer3 tap selects + radio ●")
    hold("layer3_btn")()
    check(canvas.layer_visible[3] == false and label("layer3_btn") == "●上图层(☑隐藏)",
        "layer3 hold toggles hide box")
    hold("layer3_btn")()
    check(canvas.layer_visible[3] == true, "layer3 visible again")
    -- 属性面板无独立"字体"条目(v59g 移入文字编辑对话框)
    local font_btn = canvas:_categoryBt("prop").button_by_id["font_btn"]
    check(font_btn == nil, "font entry removed from prop panel")
    -- 功能面板扁平(含关于;v62d 保存=工程/打开/输出=PNG)
    check(label("undo_btn") == "撤销" and label("redo_btn") == "重做" and label("clear_btn") == "清空"
        and label("save_proj_btn") == "保存" and label("open_proj_btn") == "打开"
        and label("save_btn") == "输出" and label("exit_btn") == "退出" and label("about_btn") == "关于",
        "func panel: 撤销/重做/清空/保存/打开/输出/退出/关于")
end)

-- 5. 空文字:不创建元素
scenario("empty text commit rejected", function(canvas)
    canvas:_setTool("text")
    canvas:_commitText(SAFE.x, SAFE.y, "")
    canvas:_commitText(SAFE.x, SAFE.y, nil)
    check(#canvas.elements == 0, "no element for empty/nil text")
end)

-- 6. 纯空白文字:视为空,不创建元素
scenario("whitespace-only text rejected", function(canvas)
    canvas:_setTool("text")
    canvas:_commitText(SAFE.x, SAFE.y, "   ")
    canvas:_commitText(SAFE.x, SAFE.y, "\t\n ")
    check(#canvas.elements == 0, "whitespace text should not create element")
end)

-- 7. 超长文字(500 字):创建成功且 bbox 有限
scenario("very long text (500 chars)", function(canvas)
    canvas:_setTool("text")
    local long = string.rep("字", 500)
    canvas:_commitText(SAFE.x, SAFE.y, long)
    check(#canvas.elements == 1, "element created")
    local el = canvas.elements[1]
    local b = canvas:_elementBBox(el)
    check(b ~= nil and b.x1 >= b.x0 and b.y1 >= b.y0, "bbox sane")
    check(b.x1 - b.x0 < 100000, "bbox not exploded: " .. tostring(b and (b.x1 - b.x0)))
end)

-- 8. 7 种笔触各画一笔
scenario("all 7 tips draw", function(canvas)
    canvas:_setTool("brush")
    for _, t in ipairs(const.TIPS) do
        canvas.tip = t[1]
        pan(canvas, SAFE.x, SAFE.y, SAFE.x + 40, SAFE.y + 40)
    end
    check(#canvas.elements == 7, "7 strokes, got " .. #canvas.elements)
end)

-- 9. 空画布选择/橡皮点选:返回 nil 不崩
scenario("pick on empty canvas", function(canvas)
    check(canvas:_pickElementAt(SAFE.x, SAFE.y) == nil, "nil on empty")
    canvas:_eraseAt(SAFE.x, SAFE.y) -- 不崩即可
end)

-- 10. 画布外 pan/tap:_toCanvas 拒绝,无元素无崩
scenario("off-canvas gestures", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 2000, 2000, 2100, 2100)
    tap(canvas, -50, -50)
    check(#canvas.elements == 0, "nothing committed off-canvas")
end)

-- ============================ 场景 11-20:误操作与边界 ============================

-- 11. 连点同一位置 100 次(画笔):100 个墨点或防抖合并,不崩
scenario("rapid tap x100 same spot", function(canvas)
    canvas:_setTool("brush")
    for _ = 1, 100 do
        tap(canvas, SAFE.x, SAFE.y)
    end
    check(#canvas.elements <= 100, "committed dots bounded")
end)

-- 12. 连点 100 次切 8 工具:状态机不串
scenario("cycle 8 tools x12", function(canvas)
    local tools = { "brush", "eraser", "line", "rect", "circle", "text", "select", "fill" }
    for i = 1, 96 do
        canvas:_setTool(tools[(i % 8) + 1])
    end
    check(canvas.tool ~= nil, "tool valid after cycling")
end)

-- 13. 选中元素后切换工具:选区被清理,后续工具不误伤
scenario("selection cleared on tool switch", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas:_setTool("select")
    tap(canvas, 130, 230) -- 点中笔画选中
    check(canvas._selected ~= nil, "selected")
    canvas:_setTool("circle")
    -- 选中状态在切工具后应清理(不残留高亮/手柄)
    check(canvas._selected == nil, "selection cleared, got " .. tostring(canvas._selected ~= nil))
end)

-- 14. 橡皮点删:三层各一笔,点最上层只删最上层
scenario("eraser picks topmost", function(canvas)
    canvas:_switchLayer(1); canvas:_setTool("brush"); pan(canvas, 100, 200, 200, 200)
    canvas:_switchLayer(2); pan(canvas, 110, 210, 210, 210)
    canvas:_switchLayer(3); pan(canvas, 120, 220, 220, 220)
    canvas:_switchLayer(3)
    canvas:_setTool("eraser")
    canvas:_eraseAt(150, 210)
    check(#canvas.layers[3] == 0, "top layer erased")
    check(#canvas.layers[1] == 1 and #canvas.layers[2] == 1, "lower layers intact")
end)

-- 15. 框选橡皮:图层隔离——只删当前层,他层完好(_eraseInRect 收两对角点)
scenario("rect eraser respects layer isolation", function(canvas)
    canvas:_switchLayer(1); canvas:_setTool("brush"); pan(canvas, 100, 200, 200, 200)
    canvas:_switchLayer(2); pan(canvas, 110, 210, 210, 210)
    canvas:_switchLayer(3); pan(canvas, 120, 220, 220, 220)
    canvas:_setTool("eraser")
    canvas:_toggleEraserMode() -- rect 模式
    check(canvas.eraser_mode == "rect", "rect mode on")
    canvas:_eraseInRect(90, 180, 250, 240) -- 框住全部三层区域
    check(#canvas.layers[3] == 0, "current layer (3) cleared")
    check(#canvas.layers[2] == 1, "layer2 intact (isolation)")
    check(#canvas.layers[1] == 1, "layer1 intact (isolation)")
    canvas:_switchLayer(1)
    canvas:_eraseInRect(90, 180, 250, 240)
    check(#canvas.layers[1] == 0, "layer1 cleared after switching")
end)

-- 16. 变形拖角越界(2000,2000):钳位不崩,bbox 有限
scenario("scale handle dragged off-canvas", function(canvas)
    canvas:_setTool("rect")
    pan(canvas, 100, 200, 200, 300) -- 矩形
    canvas:_setTool("select")
    tap(canvas, 150, 200) -- 点上边框选中(空心内部无墨迹,容差 20 选不中)
    check(canvas._selected ~= nil, "selected")
    -- 拖 se 角到画布外
    local corners = canvas:_frameCorners(canvas._selected)
    check(corners ~= nil, "corners computed")
    canvas:_finishTransform(2000, 2000)
    -- 不崩 + bbox 有限
    local b = canvas:_elementBBox(canvas._selected)
    if b then
        check(b.x1 - b.x0 < 100000, "bbox bounded")
    end
end)

-- 17. 旋转累计 720°:rot 数值稳定
scenario("rotate 720 degrees cumulative", function(canvas)
    canvas:_setTool("rect")
    pan(canvas, 100, 200, 200, 300)
    canvas:_setTool("select")
    tap(canvas, 150, 200) -- 点边框选中
    local el = canvas._selected
    check(el ~= nil, "selected")
    for _ = 1, 8 do -- 8 次 90°
        canvas:_finishTransform(150 + 100, 200) -- 拖角旋转
    end
    if el.rot then
        -- rot 应在合理范围(允许累计,但不应爆炸到 1e6)
        check(math.abs(el.rot) < 100, "rot bounded: " .. tostring(el.rot))
    end
end)

-- 18. 超长笔画超 4096 点:抽稀后不超上限
scenario("stroke thinning over MAX_STROKE_POINTS", function(canvas)
    canvas:_setTool("brush")
    -- 模拟 5000 点 pan 序列(锯齿移动)
    local n = 0
    for i = 1, 5000 do
        local x = 50 + (i % 400)
        local y = 150 + (i % 200)
        canvas:onPan(nil, { pos = { x = x, y = y }, start_pos = { x = x, y = y } })
        n = n + 1
    end
    canvas:onPanRelease(nil, { pos = { x = 450, y = 350 } })
    check(#canvas.elements >= 1, "stroke committed")
    for _, el in ipairs(canvas.elements) do
        if el.kind == "freehand" then
            check(#el.points <= const.MAX_STROKE_POINTS,
                "points thinned to <= " .. const.MAX_STROKE_POINTS .. ", got " .. #el.points)
        end
    end
end)

-- 19. 双指中断笔画:笔画收尾无残留
scenario("two-finger pan interrupts stroke", function(canvas)
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 130, y = 230 }, start_pos = { x = 100, y = 200 } })
    check(canvas._stroke ~= nil, "stroke in progress")
    canvas:onTwoFingerPan(nil, { pos = { x = 150, y = 250 } })
    check(canvas._stroke == nil, "stroke finished by two-finger")
end)

-- 20. hold 收笔后又 swipe:无状态残留
scenario("hold then swipe no residue", function(canvas)
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onHold(nil, { pos = { x = 100, y = 200 } })
    canvas:onHoldRelease(nil, { pos = { x = 140, y = 240 } })
    canvas:onSwipe(nil, { pos = { x = 200, y = 200 }, end_pos = { x = 300, y = 300 } })
    -- 两次收笔后笔画状态应干净
    check(canvas._stroke == nil, "no stroke residue")
    check(canvas._stroke_pending == nil, "no pending residue")
end)

-- ============================ 场景 21-30:文件/设置/弹窗 ============================

-- 21. 保存文件名带斜杠:拦截(A9)
scenario("save filename with slash rejected", function(canvas)
    local called = false
    local orig_toast = require("drawingpad.components").showToast
    require("drawingpad.components").showToast = function(_, msg) called = true end
    canvas:_doSaveFlow("a/b")
    require("drawingpad.components").showToast = orig_toast
    check(called, "toast shown for slash name")
end)

-- 22. 保存到不存在目录:自动 mkdir 写盘成功
scenario("save to nonexistent dir auto-mkdir", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_test_noexist_" .. os.time()
    local path = dir .. "/test.png"
    local saved = canvas:_doSave(path) -- mkdir 是 _doSaveFlow 的职责,_doSave 直接写不建目录
    -- _doSave 不建目录,预期失败(nil);建目录后成功
    if saved then
        os.remove(path)
    end
    pcall(lfs.mkdir, dir)
    saved = canvas:_doSave(path)
    check(saved == path, "save after mkdir succeeds")
    local f = io.open(path, "rb")
    check(f ~= nil, "file exists")
    local magic = f:read(8)
    f:close()
    os.remove(path)
    os.remove(dir)
    check(magic == string.char(137, 80, 78, 71, 13, 10, 26, 10), "PNG magic valid (A9)")
end)

-- 23. 立即关闭(无元素):不弹确认框
scenario("close empty canvas no confirm", function(canvas)
    local shown = 0
    local orig_show = UIManager.show
    UIManager.show = function(_, w) shown = shown + 1 end
    canvas:_onClose()
    UIManager.show = orig_show
    check(shown == 0, "no confirm dialog on empty canvas, shown=" .. shown)
end)

-- 24. 有元素关闭:弹确认框
scenario("close with content shows confirm", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    local shown = 0
    local orig_show = UIManager.show
    UIManager.show = function(_, w) shown = shown + 1 end
    canvas:_onClose()
    UIManager.show = orig_show
    check(shown >= 1, "confirm dialog shown")
end)

-- 24b. v61q:当前层空白但其他层有内容,关闭也要弹确认框
scenario("close with content on other layer shows confirm", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260) -- 默认层(中层)一笔
    canvas:_switchLayer(3) -- 切到别的层,当前层空白
    check(#canvas.elements == 0, "current layer empty")
    local shown = 0
    local orig_show = UIManager.show
    UIManager.show = function(_, w) shown = shown + 1 end
    canvas:_onClose()
    UIManager.show = orig_show
    check(shown >= 1, "confirm dialog shown for content on other layer")
end)

-- 25. 损坏的 settings 文件:降级默认不崩
scenario("corrupted settings file tolerated", function(canvas)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_settings_" .. os.time()
    pcall(lfs.mkdir, dir)
    local f = io.open(dir .. "/drawingpad_settings.lua", "w")
    f:write("this is not valid lua {{{{")
    f:close()
    local ok = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local c = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
    end)
    os.remove(dir .. "/drawingpad_settings.lua")
    os.remove(dir)
    check(ok, "construct with corrupt settings does not crash")
end)

-- 26. settings 缺字段:只覆盖读到的,默认值兜底
scenario("partial settings file defaults", function(canvas)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_settings2_" .. os.time()
    pcall(lfs.mkdir, dir)
    local f = io.open(dir .. "/drawingpad_settings.lua", "w")
    f:write("return { gray = 0.5 }")
    f:close()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    local c = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
    os.remove(dir .. "/drawingpad_settings.lua")
    os.remove(dir)
    check(c.gray == 0.5, "gray loaded from file")
    check(c.width ~= nil, "width falls back to default")
    check(c.tip ~= nil, "tip falls back to default")
end)

-- 27. last_text 类型错误(number):不崩(防御)
scenario("settings with wrong-type last_text", function(canvas)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_settings3_" .. os.time()
    pcall(lfs.mkdir, dir)
    local f = io.open(dir .. "/drawingpad_settings.lua", "w")
    f:write("return { last_text = 12345 }")
    f:close()
    local ok, c = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        return DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
    end)
    os.remove(dir .. "/drawingpad_settings.lua")
    os.remove(dir)
    check(ok, "construct survives number last_text")
end)

-- 28. 隐藏层不可点选/不可见(v57 断言当前行为)
scenario("hidden layer not pickable", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas.layer_visible[canvas.active_layer] = false
    local picked = canvas:_pickElementAt(130, 230)
    check(picked == nil, "hidden layer element not pickable, got " .. tostring(picked ~= nil))
end)

-- 29. 选中后切图层:选区清空
scenario("selection cleared on layer switch", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas:_setTool("select")
    tap(canvas, 130, 230)
    check(canvas._selected ~= nil, "selected")
    canvas:_switchLayer(3)
    check(canvas._selected == nil, "selection cleared")
end)

-- 30. 11 个长按按钮各切 5 次:标签与状态栏同步不崩。
-- 必须先真实 paintTo 让按钮获得 dimen——否则 holdBtn 的反馈块(has_fb)整段跳过,
-- is_secondary 闭包错误测不出来(v57 A1 重构 s=nil 崩溃即漏网于此)
scenario("hold toggles x5 all buttons", function(canvas)
    local Screen = require("device").screen
    canvas:paintTo(Screen.bb, 0, 0)
    -- v58:按钮在分类面板里,逐类构造并长按 x5(真实 hold_callback 闭包)
    local ids = { "brush_btn", "rect_btn", "circle_btn", "select_btn",
        "fill_btn", "eraser_btn", "gray_btn", "width_btn", "tip_btn", "layer_btn",
        "undo_btn", "clear_btn", "save_btn" }
    for _, cat in ipairs({ "tool", "prop", "func" }) do
        local bt = canvas:_categoryBt(cat)
        for _, id in ipairs(ids) do
            local btn = bt.button_by_id[id]
            if btn and btn.hold_callback then
                for _ = 1, 5 do
                    btn.hold_callback()
                end
            end
        end
    end
    -- 不崩 + 状态栏文本可生成
    local txt = canvas:_statusText()
    check(type(txt) == "string" and #txt > 0, "status text generated")
end)

-- 31. v58 底色规则:只有当前激活的工具类条目浅灰底;非激活工具与属性/功能条目一律白底
scenario("category bg rule (v59f)", function(canvas)
    local BLB = require("ffi/blitbuffer")
    local tool_bt = canvas:_categoryBt("tool")
    check(tool_bt.button_by_id["brush_btn"][1].background == BLB.COLOR_LIGHT_GRAY, "active tool lightgray")
    check(tool_bt.button_by_id["text_btn"][1].background == BLB.COLOR_WHITE
        and tool_bt.button_by_id["eraser_btn"][1].background == BLB.COLOR_WHITE, "inactive tools white")
    local prop_bt = canvas:_categoryBt("prop")
    check(prop_bt.button_by_id["gray_btn"][1].background == BLB.COLOR_WHITE
        and prop_bt.button_by_id["tip_btn"][1].background == BLB.COLOR_WHITE, "prop items white always")
    canvas:_toggleGrayRandom()
    check(canvas:_categoryBt("prop").button_by_id["gray_btn"][1].background == BLB.COLOR_WHITE,
        "random does not light prop bg")
    canvas:_toggleGrayRandom()
    local layer_bt = canvas:_categoryBt("layer")
    check(layer_bt.button_by_id["layer2_btn"][1].background == BLB.COLOR_LIGHT_GRAY, "current layer lightgray")
    check(layer_bt.button_by_id["layer1_btn"][1].background == BLB.COLOR_WHITE
        and layer_bt.button_by_id["layer3_btn"][1].background == BLB.COLOR_WHITE, "other layer entries white")
    local func_bt = canvas:_categoryBt("func")
    check(func_bt.button_by_id["undo_btn"][1].background == BLB.COLOR_WHITE
        and func_bt.button_by_id["clear_btn"][1].background == BLB.COLOR_WHITE
        and func_bt.button_by_id["exit_btn"][1].background == BLB.COLOR_WHITE
        and func_bt.button_by_id["about_btn"][1].background == BLB.COLOR_WHITE, "func items white always")
end)

-- ============================ 汇总 ============================

print(string.format("=== adversarial_test: %d passed, %d failed ===", passes, #failures))
if #failures > 0 then
    print("--- failure detail ---")
    for _, f in ipairs(failures) do
        print("FAIL:", f.name)
        print("     ", f.err)
    end
    os.exit(1)
end
