--[[--
drawingpad.drawing_canvas — 绘图板全屏画板 widget(DrawingCanvas)。
本文件为核心与组装:类定义/init/布局绘制/日志/崩溃保护,
各功能模块方法由下方混合合并:
- const.lua      常量与工具函数
- geometry.lua   几何计算与变换(包围盒/区域/缩放/旋转/平移/克隆)
- tools.lua      工具状态与切换
- gestures.lua   手势入口(tap/pan/swipe/hold)
- strokes.lua    画笔/橡皮/图形工具与刷新节流
- select.lua     选择对象(移动/复制)与变形(缩放/旋转锚点)
- layers.lua     图层
- menus.lua      工具栏/状态栏/居中弹窗/文字/调色板/保存文件夹
- actions.lua    撤销/重做/清空/刷新/保存/关闭

用法(与 tools/wbuilder.lua 的挂载方式一致):
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    local canvas = DrawingCanvas:new{ on_close = function() end }
    UIManager:show(canvas)
--]]

-- 自定位:把本文件所在目录加入 package.path,使 require("shapes") 与目录无关
-- (插件目录或 frontend/ 两种放置方式都能加载)
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- 同目录短名(shapes/const)与父目录 drawingpad.* 前缀皆可解析,与 drawingpad 所在位置无关
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local RenderText = require("ui/rendertext")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local const = require("drawingpad.const")
local L = require("drawingpad.i18n")

local DrawingCanvas = InputContainer:extend{
    name = "DrawingCanvas",
    on_close = nil,      -- 关闭回调(插件用;wbuilder 测试可传空函数)
    log_path = nil,      -- 调试日志文件(插件传入插件目录路径;nil 则只打控制台)
    tool = "brush",      -- 当前工具
    gray = 1.0,          -- 固定模式当前灰度 0(白)..1(黑)
    width = 4,           -- 固定模式当前线宽
    -- 灰度随机分级(长按灰度键切换固定/随机):随机模式每次落笔从 [gray_min,gray_max]
    -- 均分 gray_levels 级随机取一个灰度("2"=只在最小/最大之间随机)
    gray_min = 0.1,
    gray_max = 0.9,
    gray_levels = 8,
    gray_random = false,
    -- 粗细随机分级(长按粗细键切换固定/随机)
    width_min = 2,
    width_max = 32,
    width_levels = 8,
    width_random = false,
    -- 透明度(0-1,1=不透明)随机分级(长按透明度键切换固定/随机):
    -- 随机模式每次落笔从 [alpha_min,alpha_max] 均分 alpha_levels 级随机取
    alpha = 1.0,
    alpha_min = 0.3,
    alpha_max = 1.0,
    alpha_levels = 8,
    alpha_random = false,
    tip = "circle",      -- 笔触形状(仅画笔/直线):circle/square/triangle/triangle_inv/diamond/slash/backslash
    save_folder = "",    -- 保存子文件夹(相对 drawingboard/ 根目录,""=根目录)
    -- 图层:3 层独立元素列表与撤销/重做栈;self.elements/undo/redo 指向当前层引用
    -- v61r:默认层改为中层(2)——上层留给叠加批注、下层留给底稿,新内容默认落中层
    active_layer = 2,
    font = nil,          -- 文字字体(fonts 目录字体文件名,init 时取默认)
    font_size = 24,      -- 文字字号(无极调节)
    _minimized = false,  -- 工具栏是否最小化
    preview = nil,       -- 图形工具停留 1s 后显示的预览元素(收笔/移动时清除)
    rect_filled = false,   -- 矩形 实心/空心(长按矩形切换)
    circle_filled = false, -- 圆形 实心/空心(长按圆形切换)
    eraser_mode = "brush", -- 橡皮:brush=画笔删(轨迹) / rect=框选删(框选)(长按橡皮切换)
    fill_mode = "tap",  -- 填充:tap=点填封闭区域 / path=画笔描边,闭合起点落点后填内部(长按切换)
    select_mode = "move",  -- 选择工具:move=移动 / copy=复制(长按选择按钮切换)
    -- 模态:未注册的手势(swipe/hold 等)不穿透到下层窗口
    stop_events_propagation = true,
}

function DrawingCanvas:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true -- UIManager repaint 提示
    -- 随机灰度/粗细用 math.random;KOReader 的 frontend/random.lua 不保证被加载,
    -- 这里播种一次,保证每次打开画板随机序列不同
    math.randomseed(os.time())
    -- 图层:3 层独立元素列表与撤销/重做栈;self.elements/undo/redo 是指向当前层的引用,
    -- 切层时重绑,现有元素读写与撤销重做代码无需感知图层
    self.layers = { {}, {}, {} }
    self.layers_undo = { {}, {}, {} }
    self.layers_redo = { {}, {}, {} }
    self.active_layer = 2 -- v61r:默认中层(上层留批注、下层留底稿)
    self.elements = self.layers[2]   -- 当前层元素(绘制顺序)
    self.undo = self.layers_undo[2]  -- 撤销栈(操作记录:{kind="add",el} / {kind="del",els,idxs} / {kind="move",el,dx,dy} / {kind="transform",el,orig,final})
    self.redo = self.layers_redo[2]  -- 重做栈(操作记录)
    self.layer_visible = { true, true, true } -- 每层显示/隐藏(长按图层键切换;隐藏=不渲染、不导出)
    self.layer_alpha = { 1.0, 1.0, 1.0 } -- 每层整体透明度(图层面板"当前层透明度";1=不透明,会话级)
    -- 显隐切换的乒乓缓存:_vis_cache = {mask=可见层掩码, bb=该状态的整幅画面}。
    -- 元素一有变动即作废;交替显隐(对比图层)时第 2 次起整幅交换缓冲,零重绘
    self._vis_cache = nil
    self._canvas_mask = nil -- canvas_bb 当前内容对应的可见层掩码
    self._stroke = nil   -- 画笔/橡皮进行中的笔画
    self._shape_start = nil -- 图形工具锚点
    self._stroke_region = nil -- 笔画节流期累积刷新区域
    self._stroke_repaint_pending = false -- 是否已排节流重绘
    -- UIManager:scheduleIn 返回 nil 取不到任务句柄,但 unschedule 按"闭包引用"取消,
    -- 所以把调度时同一个闭包存下来,关闭/切工具时才能真正取消挂起任务
    self._stroke_repaint_fn = nil -- 笔画节流重绘定时任务闭包
    self._shape_preview_fn = nil  -- 图形预览定时任务闭包
    self._stroke_pending = nil -- 画笔起笔防抖:按下点(移动达阈值才转正式笔画)
    self._selected = nil   -- 选择工具:当前选中元素
    self._handle_mode = "scale" -- 选择工具:四角锚点模式 scale=缩放方块 / rotate=旋转圆点(再次点选切换)
    self._select_drag = nil -- 选择工具:拖动起点(画布坐标)
    self._transform = nil  -- 选择工具:变形进行中(锚点拖动:{handle,x0,y0,bbox,old_region,orig})
    self._drag_preview = nil -- 选择工具 拖拽(移动/旋转/缩放)预览元素(画在屏幕 BB,不污染画布)
    self._drag_preview_fn = nil -- 预览首次显示定时任务闭包(停满 0.5s 才显示=停止位置防抖)
    self._drag_preview_region = nil -- 预览累积刷新区域(收笔/移动时刷新擦除)
    self._drag_preview_pos = nil -- 预览定时器记录的最新手指位置
    self._drag_preview_repaint_pending = false -- 预览跟随刷新节流:窗口内只排一次重绘
    self._drag_preview_repaint_fn = nil -- 预览跟随刷新节流定时任务闭包

    self:_loadSettings() -- 读取上次保存的工具设置(插件目录;无插件目录时跳过)

    -- v62h:语言解析必须在任何 UI 构造前——menu_lang 设置优先,缺省按系统语言 auto
    -- (系统语言非中文 → 英文菜单)。L 是 i18n 单例,resolve 一次全局生效
    L.resolve(self.menu_lang)

    self:_log("init", Screen:getWidth(), "x", Screen:getHeight())
    -- 字体已从设置恢复则不覆盖(否则 _loadSettings 存的字体被默认字体顶掉);首次运行才取默认
    self.font = self.font or self:_defaultFont()
    self:_buildToolbar()
    self:_buildRestoreButton()
    self:_buildStatus()

    self:_updateHeader()
    self:_recreateCanvas()
    self._status = self:_statusText()

    -- 起笔死区调优:画板期间调低手势 PAN_THRESHOLD(起笔曲线优化),关闭时在 onCloseWidget 还原
    self:_applyGestureTuning()

    -- 手势注册(ImageViewer 同款模式):画布区域接收 tap/pan/pan_release
    local range = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        -- 收笔前短暂停留会被判定为 hold 系手势(hold_pan/hold_release)而非 pan/pan_release;
        -- 不处理会导致上一笔不落盘、下一笔错误相连
        Hold = { GestureRange:new{ ges = "hold", range = range } },
        HoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
        -- 快速拖动会被判定为 swipe 而非 pan,必须注册,否则快画没反应
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        -- 甩动轨迹有方向变化时,快速拖动会被判定为 multiswipe 而非 swipe;
        -- 不注册会被 stop_events_propagation 吞掉,描边填/画笔的进行中笔画收不到收尾事件而残留
        MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = range } },
        TwoFingerPan = { GestureRange:new{ ges = "two_finger_pan", range = range } },
        Pinch = { GestureRange:new{ ges = "pinch", range = range } },
    }
    -- 头部控件放进 self[1](事件先经子组件;最小化时换为"菜单"恢复按钮)
    self[1] = self.toolbar

    -- Kindle 等带实体键设备:Back = 关闭画板(走同样的未保存确认)
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
end

-- ============================ 布局与绘制 ============================

-- 底部遮挡高度:正常 = 工具栏+状态栏(画布底部被遮挡区,不可画);
-- 最小化 = 0(工具栏隐藏,画布铺满全屏)
function DrawingCanvas:_updateHeader()
    if self._minimized then
        self.header_h = 0
    else
        self.header_h = self.toolbar_h + self.status_h
    end
end

-- 画布恒定全屏尺寸(坐标 = 屏幕坐标,最小化切换无位移);从元素栈重绘
function DrawingCanvas:_recreateCanvas()
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    if self.canvas_bb and self.canvas_bb.free then
        self.canvas_bb:free()
    end
    -- 画布尺寸可能变化:乒乓缓存一并释放
    self:_invalidateVisCache()
    self.canvas_w, self.canvas_h = w, h
    self.canvas_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    self.canvas_bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    self:_drawAllLayers()
    self._canvas_mask = self:_visibleMask()
end

-- 从所有图层重放元素到画布(层序=绘制顺序:下层→中层→上层,上层盖下层;
-- 同层按插入顺序;隐藏层跳过)
function DrawingCanvas:_drawAllLayers()
    for li = 1, 3 do
        if self.layer_visible[li] then
            for _, el in ipairs(self.layers[li]) do
                if el.kind == "text" then
                    self:_drawTextTo(self.canvas_bb, el, li)
                else
                    shapes.drawElement(self:_alphaBB(self.canvas_bb, el, li), el, Blitbuffer.gray(el.gray))
                end
            end
        end
    end
end

-- 元素绘制目标:元素/所在层带透明度时返回混合代理 bb(shapes.alphaProxy),否则原 bb。
-- 有效透明度 = 元素 alpha × 所在层 alpha;layer_idx 缺省 = 当前层
-- (实时笔画/直接提交都落当前层;_drawAllLayers/_redrawRegion 显式传层号)。
-- 屏幕预览画在 Screen BB(类型随设备可能是 BB4 等):非 BB8 时不启用混合,
-- 预览回退不透明(仅预览;提交后画布上仍正确混合)
function DrawingCanvas:_alphaBB(bb, el, layer_idx)
    local eff = ((el and el.alpha) or 1)
        * ((self.layer_alpha and self.layer_alpha[layer_idx or self.active_layer]) or 1)
    if eff >= 0.999 then
        return bb
    end
    local ok, t = pcall(bb.getType, bb)
    if ok and t ~= Blitbuffer.TYPE_BB8 then
        return bb
    end
    return shapes.alphaProxy(bb, eff)
end

-- 图层显隐切换:目标状态有缓存画面则整幅交换缓冲(零重绘),否则重放一次、
-- 旧状态画布留作缓存——交替显隐(对比图层)第 2 次起全部命中。
-- 元素一有变动(_redrawRegion/_renderAll)缓存即作废,退化为一次普通重放
function DrawingCanvas:_applyVisibilityToggle()
    local new_mask = self:_visibleMask()
    local old_mask = self._canvas_mask or new_mask
    if self._vis_cache and self._vis_cache.mask == new_mask then
        self._vis_cache.bb, self.canvas_bb = self.canvas_bb, self._vis_cache.bb
        self._vis_cache.mask = old_mask
    else
        local old_canvas = self.canvas_bb
        local spare = self._vis_cache and self._vis_cache.bb
        self._vis_cache = nil
        if not spare then
            spare = Blitbuffer.new(self.canvas_w, self.canvas_h, Blitbuffer.TYPE_BB8)
        end
        self.canvas_bb = spare
        spare:paintRect(0, 0, self.canvas_w, self.canvas_h, Blitbuffer.COLOR_WHITE)
        self:_drawAllLayers()
        self._vis_cache = { mask = old_mask, bb = old_canvas }
    end
    self._canvas_mask = new_mask
    UIManager:setDirty(self, "full")
end

-- 可见层掩码(1=下,2=中,4=上)
function DrawingCanvas:_visibleMask()
    local mask = 0
    for li = 1, 3 do
        if self.layer_visible[li] then
            mask = mask + 2 ^ (li - 1)
        end
    end
    return mask
end

-- 元素内容变动:非当前状态的缓存画面作废(区域重放只维护画布当前状态)
function DrawingCanvas:_invalidateVisCache()
    if self._vis_cache then
        if self._vis_cache.bb and self._vis_cache.bb.free then
            self._vis_cache.bb:free()
        end
        self._vis_cache = nil
    end
end

-- 最小化/恢复工具栏:画布铺满全屏,左上角留"菜单"按钮恢复
function DrawingCanvas:_toggleMinimize()
    self:_setMinimized(not self._minimized)
end

function DrawingCanvas:_setMinimized(min)
    if self._minimized == min then
        return
    end
    self._minimized = min
    self:_invalidateTasks()
    self._stroke = nil
    self._stroke_pending = nil
    self._shape_start = nil
    self._erase_path = nil
    self:_cancelShapePreview()
    self._shape_preview_region = nil
    self._shape_pos = nil
    self._select_drag = nil
    self._transform = nil
    self:_setSelected(nil)
    self:_updateHeader()
    -- 画布恒定全屏不重建:坐标屏幕锚定,切换后内容位置不变(仅头部遮挡/露出)
    -- 头部控件切换:最小化时只留"菜单"按钮,避免隐藏的工具栏误吞点击
    self[1] = min and self.restore_btn or self.toolbar
    self:_log(min and "minimized" or "restored")
    UIManager:setDirty(self, "full")
end

function DrawingCanvas:_buildStatus()
    self._status = self:_statusText()
end

-- InputContainer:paintTo 只画 self[1],这里完全接管:画布 + 底部工具栏/状态栏 + 预览
function DrawingCanvas:paintTo(bb, x, y)
    if self.dimen then
        self.dimen.x = x
        self.dimen.y = y
    end
    -- 画布全屏显示(坐标=屏幕坐标,顶部内容可见;底部被工具栏/状态栏覆盖)
    bb:blitFrom(self.canvas_bb, x, y, 0, 0, self.canvas_w, self.canvas_h)
    if not self._minimized then
        -- 状态栏:屏幕最底部(文字居中);底色 50% 灰(原近黑),黑字保证对比度
        local status_y = y + self.canvas_h - self.status_h
        bb:paintRect(x, status_y, self.canvas_w, self.status_h, Blitbuffer.COLOR_LIGHT_GRAY)
        local status_text = self._status or ""
        local st_face = Font:getFace("smallinfofont", 15)
        -- v57 超宽截断:文字超画布 95% 时砍尾部(工具名在前保住,尾部 [重做]/[清空]
        -- 等模式提示优先级最低先丢),省略号结尾。逐 UTF-8 字符回退,超宽才触发
        local st_size = RenderText:sizeUtf8Text(0, nil, st_face, status_text, false, false)
        local st_w = (st_size and st_size.x) or 0
        local max_w = math.floor(self.canvas_w * 0.95)
        if st_w > max_w and #status_text > 0 then
            local function trimLastChar(s)
                local i = #s
                while i > 1 do
                    local b = s:byte(i)
                    if b < 128 or b >= 192 then break end -- UTF-8 首字节
                    i = i - 1
                end
                return s:sub(1, math.max(0, i - 1))
            end
            while #status_text > 0
                and RenderText:sizeUtf8Text(0, nil, st_face, status_text .. "…", false, false).x > max_w do
                status_text = trimLastChar(status_text)
            end
            status_text = status_text .. "…"
            st_w = RenderText:sizeUtf8Text(0, nil, st_face, status_text, false, false).x
        end
        local st_x = x + math.floor(math.max(0, (self.canvas_w - st_w) / 2))
        RenderText:renderUtf8Text(bb, st_x, status_y + math.floor(self.status_h * 0.75),
            st_face, status_text, false, false, Blitbuffer.gray(1))
        -- 工具栏:状态栏上方
        self.toolbar:paintTo(bb, x, y + self.canvas_h - self.toolbar_h - self.status_h)
    end
    if self._minimized then
        -- 最小化后“菜单”恢复按钮固定在左下角，不遮挡画布顶部内容
        local restore_h = Screen:scaleBySize(48)
        local ok, size = pcall(function() return self.restore_btn:getSize() end)
        if ok and size and size.h then
            restore_h = size.h
        end
        self.restore_btn:paintTo(bb, x, y + self.canvas_h - restore_h)
    end
    -- 图形工具停留 1s 显示的预览(画在屏幕 BB 上,不污染画布)
    if self.preview then
        shapes.drawElement(self:_alphaBB(bb, self.preview), self.preview, Blitbuffer.gray(self.preview.gray), x, y)
    end
    -- 选择工具 拖拽(移动/旋转)停留后的预览(画在屏幕 BB,不污染画布)
    -- v61s:文字预览必须走 _drawTextTo——shapes.drawElement 不识别 text(文字渲染
    -- 在 menus 模块),旧代码对文字预览画了空气 = "文字移动/复制无预览"的根因
    if self._drag_preview then
        local pv = self._drag_preview
        if pv.kind == "text" then
            local tmp = {}
            for k, v in pairs(pv) do
                tmp[k] = v
            end
            tmp.x = (pv.x or 0) + x
            tmp.y = (pv.y or 0) + y
            self:_drawTextTo(bb, tmp)
        else
            shapes.drawElement(self:_alphaBB(bb, pv), pv, Blitbuffer.gray(pv.gray), x, y)
        end
    end
    -- 选中对象高亮框(画在屏幕 BB,不污染画布)。
    -- 倾斜椭圆/旋转矩形(poly)沿 OBB 画闭合细框(紧贴边界),其余画轴对齐框
    if self._selected then
        local el = self._selected
        local pts = self:_frameCorners(el)
        if pts then
            local hc = Blitbuffer.gray(const.UI_GRAY_HIGHLIGHT)
            local rotated = (el.kind == "circle" and (el.rot or 0) ~= 0) or el.kind == "poly"
            if rotated then
                for i = 1, #pts do
                    local p1, p2 = pts[i], pts[(i % #pts) + 1]
                    shapes.thickLine(bb, math.floor(p1.x), math.floor(p1.y),
                        math.floor(p2.x), math.floor(p2.y), 2, hc, "circle")
                end
            else
                local b = el._bbox or self:_elementBBox(el)
                if b then
                    local pad = 3
                    local hx0 = math.max(0, math.floor(b.x0) - pad)
                    local hy0 = math.max(0, math.floor(b.y0) - pad)
                    local hx1 = math.min(self.canvas_w, math.ceil(b.x1) + pad)
                    local hy1 = math.min(self.canvas_h, math.ceil(b.y1) + pad)
                    if hx1 > hx0 and hy1 > hy0 then
                        bb:paintRect(hx0, hy0, hx1 - hx0, 1, hc)
                        bb:paintRect(hx0, hy1 - 1, hx1 - hx0, 1, hc)
                        bb:paintRect(hx0, hy0, 1, hy1 - hy0, hc)
                        bb:paintRect(hx1 - 1, hy0, 1, hy1 - hy0, hc)
                    end
                end
            end
        end
    end
    -- 变形锚点(选择工具 + 有选中对象):四角手柄,位置跟随 _frameCorners(倾斜对象锚在 OBB 角上)。
    -- 缩放模式=实心方块;再次点选切换旋转模式=实心小圆点;文字不切换(始终方块)
    if self.tool == "select" and self._selected then
        local pts = self:_frameCorners(self._selected)
        if pts then
            local hs = Screen:scaleBySize(6) -- 缩放锚方块半宽(12px,视觉小巧不遮挡;命中半径 48/文字 64)
            local hc = Blitbuffer.gray(const.UI_GRAY_HIGHLIGHT) -- 与选中框同一高亮灰(界面统一)
            local rotate = self._handle_mode == "rotate"
            local function cornerAt(px, py)
                if rotate then
                    -- 旋转锚:实心小圆点(半径约 5px;命中仍按四角中心 ±HANDLE_HIT_RADIUS)
                    local r = Screen:scaleBySize(5)
                    bb:paintCircle(math.floor(px), math.floor(py), r, hc, r)
                else
                    bb:paintRect(math.floor(px) - hs, math.floor(py) - hs, hs * 2, hs * 2, hc)
                end
            end
            for _, p in ipairs(pts) do
                cornerAt(p.x, p.y)
            end
        end
    end
end

-- 局部重绘:①当前层缓存区域重放(元素增删/变形只发生在当前层);
-- ②画布区域 = 各可见层缓存区域按序合成。元素先画进"区域大小的临时 BB"再写回——
-- 不能直接画:大元素(如大面积填充)重放会越出区域,把区域外"被高层元素盖住"
-- 的像素涂回低层墨迹(低层大灰填+高层白填=灰盖白)。临时 BB 保证区域外
-- 像素零扰动、区域内与全量重放逐像素一致。
function DrawingCanvas:_redrawRegion(region)
    if not self.canvas_bb or not region then
        return
    end
    local rx0, ry0 = math.floor(region.x), math.floor(region.y)
    local rx1 = math.min(self.canvas_w, math.ceil(region.x + region.w))
    local ry1 = math.min(self.canvas_h, math.ceil(region.y + region.h))
    if rx1 <= rx0 or ry1 <= ry0 then
        return
    end
    local rw, rh = rx1 - rx0, ry1 - ry0
    -- 元素内容变动:显隐切换的缓存画面作废
    self:_invalidateVisCache()
    -- 相交元素按层序画进"区域大小的临时 BB"再写回——不能直接往 canvas_bb 画:
    -- 大元素(如大面积填充)重放会越出区域,把区域外"被高层元素盖住"的像素
    -- 涂回低层墨迹(低层大灰填+高层白填=灰盖白)。临时 BB 保证区域外像素
    -- 零扰动、区域内与全量重放逐像素一致。
    local tmp = Blitbuffer.new(rw, rh, Blitbuffer.TYPE_BB8)
    tmp:paintRect(0, 0, rw, rh, Blitbuffer.COLOR_WHITE)
    for li = 1, 3 do
        if self.layer_visible[li] then
            for _, el in ipairs(self.layers[li]) do
                local b = el._bbox or self:_elementBBox(el)
                if b and b.x0 <= rx1 and b.x1 >= rx0 and b.y0 <= ry1 and b.y1 >= ry0 then
                    local ok, err = pcall(function()
                        if el.kind == "text" then
                            -- _drawTextTo 无偏移参数:浅拷贝平移到临时 BB 坐标系
                            local t = {}
                            for k, v in pairs(el) do
                                t[k] = v
                            end
                            t.x = (el.x or 0) - rx0
                            t.y = (el.y or 0) - ry0
                            self:_drawTextTo(tmp, t, li)
                        else
                            -- drawElement 对 BB 尺寸自裁剪,负偏移自动丢弃区域外墨迹
                            shapes.drawElement(self:_alphaBB(tmp, el, li), el, Blitbuffer.gray(el.gray), -rx0, -ry0)
                        end
                    end)
                    if not ok then
                        self:_log("_redrawRegion: element render error:", tostring(err))
                    end
                end
            end
        end
    end
    self.canvas_bb:blitFrom(tmp, rx0, ry0, 0, 0, rw, rh)
    tmp:free()
end

-- 从元素栈整体重绘画布(清空/初始化时用;文字与图形分派)
function DrawingCanvas:_renderAll()
    if not self.canvas_bb then
        self:_log("_renderAll: canvas_bb is nil, skipping")
        return
    end
    self:_invalidateVisCache()
    self.canvas_bb:paintRect(0, 0, self.canvas_w, self.canvas_h, Blitbuffer.COLOR_WHITE)
    self:_drawAllLayers()
    self._canvas_mask = self:_visibleMask()
    UIManager:setDirty(self, "partial")
end

-- ============================ 调试日志 ============================

function DrawingCanvas:_log(...)
    if not const.LOG_ENABLED then
        return
    end
    local parts = { os.date("%x %X") }
    for i = 1, select("#", ...) do
        table.insert(parts, tostring(select(i, ...)))
    end
    local line = table.concat(parts, " ")
    logger.info("drawingpad: " .. line)
    if self.log_path then
        local ok, f = pcall(io.open, self.log_path, "a")
        if ok and f then
            f:write(line .. "\n")
            f:close()
        end
    end
end

-- ============================ 模块混合与稳定性加固 ============================

-- 合并各功能模块的方法表(全部挂到 DrawingCanvas 上,跨模块调用走 self:)
for _, mod in ipairs({
    require("drawingpad.geometry"),
    require("drawingpad.tools"),
    require("drawingpad.gestures"),
    require("drawingpad.strokes"),
    require("drawingpad.select"),
    require("drawingpad.layers"),
    require("drawingpad.menus"),
    require("drawingpad.actions"),
}) do
    for name, fn in pairs(mod) do
        DrawingCanvas[name] = fn
    end
end

-- KOReader 的事件回调与 scheduleIn 定时任务都没有 pcall 保护:任何 Lua 错误都会
-- 直接冒泡导致整机崩溃(crash.log 记录 traceback)。给所有入口回调统一包一层 pcall,
-- 错误只写调试日志并照常消费事件,不再炸掉整个程序。
local function wrapHandler(orig)
    return function(self, ...)
        local ok, err = pcall(orig, self, ...)
        if not ok then
            self:_log("handler error:", tostring(err))
        end
        return true
    end
end
for _, name in ipairs({
    "onTap", "onPan", "onPanRelease", "onSwipe", "onMultiSwipe",
    "onHold", "onHoldPan", "onHoldRelease",
    "onTwoFingerPan", "onPinch",
    "_maybeShowShapePreview", "_flushStrokeRepaint",
    "onClose", "onCloseWidget",
    "_undo", "_redo", "_clearAll", "_save", "_onClose",
    "_toggleMinimize", "_toggleFilled", "_toggleEraserMode",
    "_setTool", "_pickGray", "_pickWidth", "_pickAlpha",
    "_pickFont", "_pickFontSize", "_commitText",
    "_commitDot", "_toggleSelectMode",
    "_toggleGrayRandom", "_toggleWidthRandom", "_toggleAlphaRandom",
    "_switchLayer", "_toggleLayerVisible", "_showTipMenu", "_showAbout",
    "_showCategoryMenu", "_refreshToolbar", "_showSettingDialog",
    "_refreshCanvas", "_pickSaveFolder", "_doSaveFlow", "_finishTransform",
    "_pickLayerAlpha",
}) do
    if DrawingCanvas[name] then
        DrawingCanvas[name] = wrapHandler(DrawingCanvas[name])
    end
end

return DrawingCanvas
