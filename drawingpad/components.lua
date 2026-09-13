--[[--
drawingpad.components — 弹窗组件库(Modal / Dialog / Toast 基础库)。
业务层(menus/actions)不直接手写 InputContainer/FrameContainer 弹窗骨架,
统一走本库:全屏 Modal 骨架 / 圆角可拖动 Dialog / 值调节弹窗 / Toast / 按钮即时响应。

关键约定(组件内部已固化,业务层不用再管):
- 全屏 Modal 不设 covers_fullscreen:UIManager:_repaint 跳过被全屏控件盖住的画布,
  滑块实时改灰度/粗细时选中对象不重绘,效果要等关闭才出现。
- stop_events_propagation=true 时 onGesture 无条件消费所有手势,必须注册 ges_events,
  否则弹窗把输入全吞掉(关不掉/点不动,曾因此锁死画板)。
- KOReader 手势事件经 Event:new(name, args, ev) 派发,args 为 nil 也占位,
  handler 必须签名 (_, ges),否则 ges 收到 nil 崩。
- 刷新一律用延迟函数形式("ui"/"fast" + 区域),避免被全屏 partial 合并降级留残影。
- 所有事件入口包 pcall(opts.log 记录),任何 Lua 错误只记日志不炸 KOReader。
--]]

-- 自定位:把本文件所在目录加入 package.path,使 require("drawingpad.components") 与目录无关
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- 同目录短名(shapes/const)与父目录 drawingpad.* 前缀皆可解析,与 drawingpad 所在位置无关
    package.path = __self_dir .. "/?.lua;" .. __self_dir .. "/../?.lua;" .. package.path
end
local const = require("drawingpad.const")

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Size = require("ui/size")
local _ = require("gettext")

local M = {}

-- 日志:opts.log 可选;缺省静默
local function log(opts, ...)
    if opts and opts.log then
        opts.log(...)
    end
end

-- ============================ 工具 ============================

-- 按钮即时响应:去掉 Button 默认 flash_ui 反色 + yieldToEPDC 阻塞
-- (真机每次点击约 200-300ms 冻结,配 EPD 刷新积压会显得"要点多次才有反应")。
-- 应用于弹窗内 ButtonTable / 对话框 button_table 的所有按钮。
-- 坑:ButtonTable.buttons 是原始按钮定义表(无 Button 方法),真正的 Button 实例
-- 在 buttons_layout(每行数组);button_by_id 只含带 id 的按钮,不完整。
function M.instantButtons(bt)
    local rows = bt and (bt.buttons_layout or bt.buttons)
    if not rows then
        return
    end
    for _, row in ipairs(rows) do
        for _, b in ipairs(row) do
            if b and b.onTapSelectButton then
                b.onTapSelectButton = function(self)
                    if self.enabled or self.allow_tap_when_disabled then
                        if self.callback then
                            self.callback()
                        end
                    end
                    return true
                end
            end
        end
    end
end

-- ============================ Modal 基类 ============================

-- 全屏模态弹窗基类:统一骨架/手势注册规范/点空白关闭/崩溃保护。
-- opts: { name, tap_close(默认 true), log }
-- 返回 popup(InputContainer 实例);业务层往 popup[1] 放内容。
-- 不在这里 show:由具体组件(Dialog/ValuePicker)负责。
function M.newModal(opts)
    opts = opts or {}
    local popup = InputContainer:extend{
        name = opts.name or "DrawingModal",
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        stop_events_propagation = true,
    }:new{}
    if opts.tap_close ~= false then
        -- 点空白处关闭。必须注册手势:stop_events_propagation=true 会让
        -- onGesture 无条件消费所有手势,没有 ges_events 弹窗把输入全吞掉
        popup.ges_events = {
            TapSelect = {
                GestureRange:new{ ges = "tap", range = popup.dimen },
            },
        }
        popup.onTapSelect = function()
            UIManager:close(popup, "full")
            return true
        end
    end
    -- 崩溃保护:所有事件入口(含子组件/按钮回调)包 pcall,错误记日志并消费事件
    local orig_handle = popup.handleEvent
    function popup:handleEvent(ev)
        local ok, res = pcall(orig_handle, self, ev)
        if not ok then
            log(opts, "modal handleEvent error:", tostring(res))
            return true
        end
        return res
    end
    return popup
end

-- ============================ Dialog(圆角可拖动面板) ============================

-- 居中圆角白底可拖动面板弹窗(与插入文字弹窗 InputDialog 风格统一):
-- CenterContainer → MovableContainer → FrameContainer{radius, 白底} → content;
-- 不设 covers_fullscreen:拖动时下层画布能重绘,MovableContainer 移动时
-- setDirty("all") + 旧∪新区域 "ui" 刷新 → 拖动无残影。
-- opts: { name, title, content, log };返回 popup。
function M.showCenteredDialog(opts)
    opts = opts or {}
    local popup = M.newModal{ name = opts.name or "DrawingDialog", log = opts.log }
    local content = opts.content
    if opts.title then
        content = VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = opts.title, face = Font:getFace("infont", 20) },
            VerticalSpan:new{ width = Size.span.vertical_default },
            content,
        }
    end
    local mc = MovableContainer:new{
        FrameContainer:new{
            padding = Size.padding.default,
            bordersize = Size.border.default,
            radius = Size.radius.window,
            background = Blitbuffer.COLOR_WHITE,
            content,
        },
    }
    popup.movable = mc -- 与 InputDialog 的 self.movable 约定一致
    popup[1] = CenterContainer:new{
        dimen = popup.dimen,
        mc,
    }
    -- 显式传刷新类型+区域:本树 UIManager._refresh 对 nil 模式直接丢弃(避免无谓全屏刷),
    -- 不传的话弹窗只进 framebuffer、硬件永不刷新 → "弹窗看不见,拖动后才出现"。
    -- "ui" = 非闪烁刷新;区域用 modal 全屏 dimen(与关闭时画布全屏重绘一致)。
    UIManager:show(popup, "ui", popup.dimen)
    return popup, mc
end

-- 自定义点击行(自动注册 TapSelect,消除"自定义行不注册手势吞输入锁死"坑):
-- opts: { dimen, onSelect, content };返回 InputContainer 行(row[1] = content)。
function M.tapRow(opts)
    local row = InputContainer:extend{
        dimen = opts.dimen,
        onTapSelect = function()
            if opts.onSelect then
                opts.onSelect()
            end
            return true
        end,
    }:new{}
    -- 必须注册手势才会收到点按(自定义行不像 Button 自带手势);
    -- range 引用 row.dimen:中心布局在 paint 时更新 x/y,匹配用屏幕坐标
    row.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = row.dimen },
        },
    }
    row[1] = opts.content
    return row
end

-- ============================ Toast ============================

-- 统一 Toast(InfoMessage 包装)。timeout 缺省 = 常驻(点按关闭),传秒数则到时自动关
function M.showToast(text, timeout)
    local o = { text = text }
    if timeout then
        o.timeout = timeout
    end
    UIManager:show(InfoMessage:new(o))
end

-- ============================ ValuePicker(值调节弹窗) ============================

-- 值调节弹窗(选中对象灰度/粗细、全局设置、字号):滑条+预设档位+步进行。
-- opts: { title, value, min, max, unit, presets, onchange(v), onclose(v), log }
-- onchange 在值变化时调用(tap/预设/步进/拖动释放 = force;拖动中不调,避免渲染中间态);
-- onclose 在关闭时调用(写撤销等)。
-- 拖动语义:起点在滑条上=调值;其余位置=拖动面板(避免面板挡住画布上正在调整的对象)。
function M.showValuePicker(opts)
    local vmin, vmax = opts.min, opts.max
    local value = math.max(vmin, math.min(vmax, opts.value))
    local function clamp(v)
        return math.max(vmin, math.min(vmax, v))
    end
    local unit = opts.unit or ""

    -- 与居中弹窗/笔触弹窗统一:面板由 MovableContainer 承载(跟随手指、无残影)。
    -- popup/mc 由 showCenteredDialog 在函数尾部创建;这里前置声明供闭包引用
    -- (Lua 局部变量须先声明后引用,事件触发前已赋值)
    local popup, mc
    local popupPanelRect -- 当前面板区域(延迟刷新用),尾部赋值

    local panel_w = math.floor(Screen:getWidth() * const.UI_WIDTH_WIDE)
    local pbar_w = panel_w - 2 * Size.padding.large -- 滑条宽度(漏定义会致 paint 崩)
    -- 滑条比按钮略窄:减掉面板 FrameContainer 的 padding+border,保证条体完全落在
    -- 面板内容区内,任何 DPI 下都不贴边/越界(真机 DPI 放大后滑条曾压到下方按钮)
    local slider_w = pbar_w - 2 * (Size.padding.default + Size.border.default)
    -- 步进行 step_bt 后置定义,这里前置声明供 refreshValue 捕获
    local step_bt
    local function refreshValue()
        if step_bt and step_bt.button_by_id then
            local vb = step_bt.button_by_id["value_btn"]
            if vb and vb.setText then
                vb:setText(tostring(math.floor(value + 0.5)) .. unit, vb.width)
            end
        end
    end

    -- 滑条(带刻度)与下方档位数字:统一按"最大值百分比"排布——
    -- 最小值 + max*1/8..max*8/8(向下取整,如 max=100 → 1,12,25,...,100)
    local preset_values = {}
    local seen = {}
    local function addPreset(v)
        v = math.floor(v)
        if not seen[v] then
            seen[v] = true
            table.insert(preset_values, v)
        end
    end
    addPreset(vmin)
    for i = 1, 8 do
        addPreset(vmax * i / 8)
    end
    table.sort(preset_values)
    local ticks = {}
    for i, v in ipairs(preset_values) do
        ticks[i] = v
    end
    local progress = ProgressWidget:new{
        width = slider_w*0.97,
        height = Screen:scaleBySize(32), -- 比默认(scaleBySize(40))更紧凑:条体矮,不与上下按钮视觉粘连
        ticks = ticks,
        last = vmax,
        percentage = (value - vmin) / math.max(1, vmax - vmin),
    }
    local progress_frame = FrameContainer:new{
        dimen = Geom:new{ w = slider_w, h = progress.height },
        progress,
    }
    local function setProgressPct()
        progress:setPercentage((value - vmin) / math.max(1, vmax - vmin))
    end
    -- 滑条命中区域(带触摸余量);拖动中手指可能滑出滑条,由 slider_wrap 放大范围。
    -- 水平 ±20 便于点中两端值;竖直向下只扩到与预设按键的间隙边界(与布局的
    -- 3*vertical_large 同表达式,恰与按键区齐平不重叠)——旧版四边各扩 30,
    -- 向下溢出压进预设数字按键的触摸区,而事件按子控件顺序先到滑条层
    -- (slider_wrap 在 preset_bt 之前),按键被抢触点(用户实测难触控);
    -- 向上留 2px:步进行紧贴滑条顶,步进按键是更早的子控件、在自己区域内优先
    local function sliderHitRect()
        local d = progress.dimen
        if not d then
            return nil
        end
        local hit_w = Screen:scaleBySize(20)
        local hit_up = Screen:scaleBySize(2)
        local hit_down = 3 * Size.span.vertical_large
        return Geom:new{ x = d.x - hit_w, y = d.y - hit_up, w = d.w + 2 * hit_w, h = d.h + hit_up + hit_down }
    end
    -- 触摸位置 → 数值(命中滑条命中区域)
    local function posToValue(px, py)
        local r = sliderHitRect()
        if not r then
            return nil
        end
        if px < r.x or px > r.x + r.w or py < r.y or py > r.y + r.h then
            return nil
        end
        local pct = progress:getPercentageFromPosition(Geom:new{ x = px, y = py })
        if not pct then
            return nil
        end
        return clamp(vmin + math.floor(pct * (vmax - vmin) + 0.5))
    end

    -- 应用值:tap/预设/步进/拖动释放(force)= 应用到画布 + "ui" 刷新;
    -- 拖动中(非 force)= 只更新滑块 thumb/值标签,不调 onchange、不渲染画布上的对象。
    -- 逐 tick 渲染对象的中间灰度/粗细会在墨水屏上刷新积压成"拖动路径"残影
    -- (用户明确要求不需要渲染拖动时的路径),释放时 force 一次性补终态;
    -- 拖动中用 "fast" 便宜刷新,不积压不残影
    local last_apply = 0
    local APPLY_INTERVAL = 0.06
    local function applyValue(v, force)
        value = clamp(v)
        refreshValue()
        setProgressPct()
        local now = UIManager:getTime()
        if not force and now - last_apply < APPLY_INTERVAL then
            return
        end
        last_apply = now
        if force then
            if opts.onchange then
                opts.onchange(value)
            end
            -- "ui" 面板区域刷新(延迟函数:与对象区域 "ui" 刷新合并时不被降级,
            -- partial 优先级更高,直接发全屏 partial 会把对象区域降级留残影)
            UIManager:setDirty(popup, function()
                local r = popupPanelRect()
                if r then return "ui", r end
                return "ui"
            end)
        else
            UIManager:setDirty(popup, function()
                local r = popupPanelRect()
                if r then return "fast", r end
                return "fast"
            end)
        end
    end

    -- 滑条手势包装层:消费滑条上的 tap/pan/hold(防止 MovableContainer 把面板拖走);
    -- 拖动中 _dragging 时命中范围放大到全屏(手指滑出滑条仍继续调值);
    -- 释放兜底全屏,仅本层拖动中才消费,否则交还 MovableContainer(面板拖动)。
    -- 注意:KOReader 手势事件经 Event:new(name, args, ev) 派发,handler 签名必须
    -- (_, ges)——args(gsseq.args) 为 nil 也占一位,否则 ges 收到 nil 崩
    local slider_wrap
    slider_wrap = InputContainer:extend{
        dimen = Geom:new{ w = slider_w, h = progress.height },
        ges_events = {
            TapProgress = { GestureRange:new{ ges = "tap", range = function() return sliderHitRect() end } },
            PanProgress = { GestureRange:new{ ges = "pan", range = function()
                if slider_wrap._dragging then return popup.dimen end
                return sliderHitRect()
            end } },
            PanReleaseProgress = { GestureRange:new{ ges = "pan_release", range = function() return popup.dimen end } },
            HoldProgress = { GestureRange:new{ ges = "hold", range = function() return sliderHitRect() end } },
            HoldPanProgress = { GestureRange:new{ ges = "hold_pan", range = function()
                if slider_wrap._dragging then return popup.dimen end
                return sliderHitRect()
            end } },
            HoldReleaseProgress = { GestureRange:new{ ges = "hold_release", range = function() return popup.dimen end } },
        },
    }:new{}
    slider_wrap._dragging = false
    slider_wrap.hitRect = sliderHitRect -- 暴露给测试:断言触摸区不覆盖任何按键
    function slider_wrap:onTapProgress(_, ges)
        local v = posToValue(ges.pos.x, ges.pos.y)
        if v then
            applyValue(v, true)
        end
        return true -- 命中滑条区域即消费(tap 不关闭弹窗)
    end
    function slider_wrap:onPanProgress(_, ges)
        slider_wrap._dragging = true
        local v = posToValue(ges.pos.x, ges.pos.y)
        if v then
            applyValue(v, false)
        end
        return true
    end
    function slider_wrap:onPanReleaseProgress(_, ges)
        if slider_wrap._dragging then
            applyValue(value, true) -- 拖动结束补终态
            slider_wrap._dragging = false
            return true
        end
        return false -- 非滑条拖动,交给 MovableContainer
    end
    function slider_wrap:onHoldProgress(_, ges)
        return true -- 按住滑条:消费,防止 MovableContainer 拖走面板
    end
    function slider_wrap:onHoldPanProgress(_, ges)
        slider_wrap._dragging = true
        local v = posToValue(ges.pos.x, ges.pos.y)
        if v then
            applyValue(v, false)
        end
        return true
    end
    function slider_wrap:onHoldReleaseProgress(_, ges)
        return slider_wrap:onPanReleaseProgress(_, ges)
    end
    slider_wrap[1] = progress_frame

    -- 预设档位(每行 5 个,值已按最大值百分比生成)
    local preset_rows = {}
    for i = 1, #preset_values, 5 do
        local row = {}
        for j = i, math.min(i + 4, #preset_values) do
            local pv = preset_values[j]
            table.insert(row, {
                text = tostring(pv) .. unit,
                callback = function()
                    applyValue(pv, true)
                end,
            })
        end
        table.insert(preset_rows, row)
    end
    local preset_bt = ButtonTable:new{
        width = pbar_w,
        buttons = preset_rows,
        zero_sep = true,
        show_parent = popup,
    }
    local close_bt = ButtonTable:new{
        width = pbar_w,
        buttons = {{
            { text = _("关闭"), callback = function() UIManager:close(popup, "full") end },
        }},
        show_parent = popup,
    }

    -- 步进行(滑条上方):-10/-1/[数值]/+1/+10,中间数值黑色显示实时更新(无操作)
    step_bt = ButtonTable:new{
        width = pbar_w,
        zero_sep = true,
        buttons = {{
            { text = "-10", callback = function() applyValue(value - 10, true) end },
            { text = "-1", callback = function() applyValue(value - 1, true) end },
            { id = "value_btn", text = tostring(math.floor(value + 0.5)) .. unit, enabled = true, callback = function() end },
            { text = "+1", callback = function() applyValue(value + 1, true) end },
            { text = "+10", callback = function() applyValue(value + 10, true) end },
        }},
        show_parent = popup,
    }

    -- 弹窗按钮即时响应(与文字弹窗一致,公共组件)
    M.instantButtons(step_bt)
    M.instantButtons(preset_bt)
    M.instantButtons(close_bt)

    -- 面板 + 统一外壳:与居中弹窗/笔触弹窗完全一致(CenterContainer→MovableContainer→
    -- FrameContainer 圆角白底)。面板拖动由 MovableContainer 内建(跟随手指、
    -- setDirty("all") + 旧∪新 "ui" 刷新,无残影、无轮廓);滑条拖动由 slider_wrap 消费。
    -- 注:ButtonTable 不传 show_parent(flash 路径已被 instantButtons 取代,无影响)
    -- 标题统一走 showCenteredDialog 的标题机制(20 号,与所有弹窗一致)
    popup, mc = M.showCenteredDialog{
        name = "DrawingValuePicker",
        title = opts.title,
        content = VerticalGroup:new{
            align = "center",
            step_bt,
            -- VerticalSpan:new{ width = Size.span.vertical_large }, -- 滑条与步进行拉开,防真机 DPI 放大后粘连
            slider_wrap,
            VerticalSpan:new{ width = 3*Size.span.vertical_large }, -- 滑条与预设档位按钮拉开,防重叠/越界
            preset_bt,
            VerticalSpan:new{ width = Size.span.vertical_default },
            close_bt,
        },
        log = opts.log,
    }
    popup.min = vmin -- 暴露给测试/调用方断言取值范围
    popup.max = vmax
    -- 当前面板区域(延迟刷新用):MovableContainer dimen 在 paint 时更新
    popupPanelRect = function()
        local d = mc.dimen
        if not d then
            return nil
        end
        return Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
    end
    -- 关闭时回调(写撤销等)
    local orig_close_widget = popup.onCloseWidget
    function popup:onCloseWidget()
        if opts.onclose then
            opts.onclose(value)
        end
        if orig_close_widget then
            orig_close_widget(self)
        end
    end
    log(opts, "value picker shown", opts.title or "")
end

return M
