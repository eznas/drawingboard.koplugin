--[[--
回归:面板底色实时跟随切换 + 选中文字时灰度/粗细走元素级调节
1. 工具面板打开时切换工具,激活条目浅灰底实时跟手
2. 图层面板打开时切层,当前层浅灰底实时跟手
3. 选中文字对象点"灰度":弹元素级灰度滑条并实时生效(旧版 _setTool 先清选中 → 弹成全局设置)
4. 选中对象点"粗细":保持选中(文字提示无线宽,不弹全局)

运行(从 KOReader 模拟器根目录):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/panel_live_test.lua
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

local BLB = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
UIManager.show = function(self_w, w) end
UIManager.close = function(self_w, w, ...) end

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

-- ============ 1. 工具面板底色实时刷新 ============
do
    local c = newCanvas()
    c:_setTool("brush")
    c._panel_bt = c:_categoryBt("tool") -- 模拟面板打开
    local bt = c._panel_bt
    check(bt.button_by_id["brush_btn"][1].background == BLB.COLOR_LIGHT_GRAY
        and bt.button_by_id["rect_btn"][1].background == BLB.COLOR_WHITE,
        "tool panel: brush active gray at open")
    c:_setTool("rect")
    check(bt.button_by_id["brush_btn"][1].background == BLB.COLOR_WHITE
        and bt.button_by_id["rect_btn"][1].background == BLB.COLOR_LIGHT_GRAY,
        "tool panel: highlight follows tool switch live")
end

-- ============ 2. 图层面板底色实时刷新 ============
do
    local c = newCanvas()
    c._panel_bt = c:_categoryBt("layer")
    local bt = c._panel_bt
    check(bt.button_by_id["layer2_btn"][1].background == BLB.COLOR_LIGHT_GRAY
        and bt.button_by_id["layer3_btn"][1].background == BLB.COLOR_WHITE,
        "layer panel: default middle layer active gray at open")
    c:_switchLayer(3)
    check(bt.button_by_id["layer1_btn"][1].background == BLB.COLOR_WHITE
        and bt.button_by_id["layer3_btn"][1].background == BLB.COLOR_LIGHT_GRAY,
        "layer panel: highlight follows layer switch live")
    -- 文字角标(●/○)也同步
    check(bt.button_by_id["layer3_btn"].text == "●上图层(☐隐藏)",
        "layer panel: text mark syncs too")
end

-- ============ 3. 选中文字 → 灰度走元素级 ============
do
    local c = newCanvas()
    local el = { kind = "text", text = "测试", font = "cfont", size = 30,
        x = 200, y = 200, gray = 1 }
    table.insert(c.elements, el)
    c:_cacheBBox(el)
    c:_setTool("select")
    c:_setSelected(el)
    local captured = {}
    local orig_picker = c._showValuePicker
    c._showValuePicker = function(s, opts) captured[#captured + 1] = opts end
    -- 走真入口:属性面板 gray_btn 的 on_tap
    local bt = c:_categoryBt("prop")
    -- 重新构造后回调里的 self 绑定 canvas;直接调定义的 on_tap 语义等价
    for _, t in ipairs(require("drawingpad.menus")._toggle_buttons) do
        if t.id == "gray_btn" then
            t.on_tap(c)
        end
    end
    check(#captured == 1 and captured[1].title and captured[1].title:find("选中对象") ~= nil,
        "with text selected, gray opens element picker (not global settings)")
    check(c._selected == el, "selection preserved")
    captured[1].onchange(30)
    check(math.abs(el.gray - 0.3) < 0.001, "element gray applied to text, got " .. tostring(el.gray))
    -- 渲染验证:文字区域出现中间灰墨
    c.canvas_bb:fill(BLB.COLOR_WHITE)
    c:_redrawRegion({ x = 0, y = 0, w = c.canvas_w, h = c.canvas_h })
    local mid = 0
    for y = 150, 260 do
        for x = 150, 320 do
            local a = c.canvas_bb:getPixel(x, y).a
            if a >= 100 and a <= 180 then
                mid = mid + 1
            end
        end
    end
    check(mid > 50, "text renders in gray ink, mid pixels=" .. mid)
    c._showValuePicker = orig_picker

    -- 4. 选中对象点粗细:保持选中(文字走"无线宽"提示,不弹全局粗细)
    local captured_w = {}
    c._showValuePicker = function(s, opts) captured_w[#captured_w + 1] = opts end
    for _, t in ipairs(require("drawingpad.menus")._toggle_buttons) do
        if t.id == "width_btn" then
            t.on_tap(c)
        end
    end
    check(#captured_w == 0 and c._selected == el,
        "width with text selected: no global picker, selection preserved")
    c._showValuePicker = orig_picker
end

-- ============ 5. 一级底栏:无图标背景反馈(v61k 取消灰底/闪烁,激活指示=顶部断线) ============
do
    local c = newCanvas()
    c:_showCategoryMenu("func")
    local cell = c.toolbar[2][6] -- cat_func 是第 6 格
    check(cell.background == nil and tostring(cell[1][1].background or "") ~= "Color8(128)",
        "open category cell has no gray background feedback")
    -- 面板关闭后工具栏保持干净
    c._open_cat = nil
    c:_refreshToolbar()
    check(c.toolbar[2][6].background == nil, "closing panel keeps toolbar clean")
end

-- ============ 7. 属性设置不切换当前工具(v61o:填充下点灰度/粗细保持填充) ============
do
    local c = newCanvas()
    c:_setTool("fill")
    local bt = c:_categoryBt("prop")
    local gray_tap = bt.button_by_id["gray_btn"].callback
    local width_tap = bt.button_by_id["width_btn"].callback
    gray_tap() -- 全局灰度设置弹窗(UIManager.show 已 stub)
    check(c.tool == "fill", "gray tap keeps fill tool")
    width_tap()
    check(c.tool == "fill", "width tap keeps fill tool")
    local gray_hold = bt.button_by_id["gray_btn"].hold_callback
    gray_hold()
    check(c.tool == "fill" and c.gray_random == true, "gray hold toggles random, keeps fill tool")
    -- 选中的填充对象不存在元素级分支,但选中文字对象仍走元素级(第 4 节已覆盖)
    local width_hold = bt.button_by_id["width_btn"].hold_callback
    width_hold()
    check(c.tool == "fill" and c.width_random == true, "width hold toggles random, keeps fill tool")
end

print(string.format("=== panel_live_test: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
