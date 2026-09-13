--[[--
drawingpad.gestures — 手势入口方法(DrawingCanvas 混合模块)。
tap/pan/swipe/hold 系全部在此分派到 画笔/橡皮/图形/选择 各逻辑。
--]]

-- 自定位:把本文件所在目录加入 package.path,使 require("shapes") 与目录无关
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- 同目录短名(shapes/const)与父目录 drawingpad.* 前缀皆可解析,与 drawingpad 所在位置无关
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")

local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local const = require("drawingpad.const")

local M = {}

function M:onTap(_, ges)
    local committed = false -- 点按是否改变墨迹/对象(决定是否抬笔全刷;文字弹窗/纯选中也算轻量变更不刷)
    if ges and ges.pos then
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        if x then
            if self.tool == "text" then
                self:_showTextDialog(x, y)
            elseif self.tool == "eraser" then
                -- 橡皮点按:删除该对象
                self:_eraseAt(x, y)
                committed = true
            elseif self.tool == "fill" then
                -- 点填:洪泛填充点击点所在封闭区域;描边填模式轻点为墨点
                if self.fill_mode == "tap" then
                    self:_fillAt(x, y)
                else
                    self:_commitDot(x, y)
                end
                committed = true
            elseif self.tool == "brush" then
                -- 快速轻触:产生一个墨点(防抖不拦截主动轻点);
                -- 若上一手势遗留未收笔笔画,先按末点收笔防连接
                if self._stroke then
                    self:_finishStroke(nil)
                end
                self:_commitDot(x, y)
                committed = true
            elseif self.tool == "select" then
                -- 点选/取消选中;再次点选已选中对象:切换 缩放/旋转 锚点
                local el = self:_pickElementAt(x, y)
                if el and el == self._selected then
                    self._handle_mode = (self._handle_mode == "rotate") and "scale" or "rotate"
                    UIManager:setDirty(self, "partial", self:_handleRegion(el))
                else
                    self:_setSelected(el)
                end
            end
        end
    end
    if committed then
        self:_penUpRefresh()
    end
    return true
end

function M:onPan(_, ges)
    if not ges or not ges.pos then
        return true
    end
    local tool = self.tool
    local brush_like = tool == "brush" or (tool == "fill" and self.fill_mode == "path")
    if brush_like or tool == "eraser" then
        if tool == "eraser" then
            if self.eraser_mode == "rect" then
                -- 矩形框擦:拖动只记锚点(0.5s 灰框预览),收笔删框内对象
                self:_trackShapeAnchor(ges)
            else
                -- 画笔擦:拖动收集路径,收笔删相交对象(不绘制不刷新)
                self:_trackErasePath(ges)
            end
            return true
        end
        -- 画笔起笔防抖:先记按下点(pending),移动未达阈值不落墨(吸收起笔抖动);
        -- 达到阈值后正式起笔,首点=按下点,画"按下点→当前点"段
        -- 跨手势保护:存在进行中笔画但按下点 ≠ 笔画首点 = 上一手势漏了收笔
        -- (如双指打断未收 pan_release),先按末点收笔,防止新笔起笔连接上一笔末笔
        if self._stroke and ges.start_pos then
            local first = self._stroke.points[1]
            if first and (ges.start_pos.x ~= first.x or ges.start_pos.y ~= first.y) then
                self:_finishStroke(nil)
            end
        end
        if not self._stroke and ges.start_pos then
            local sx, sy = self:_toCanvas(ges.start_pos.x, ges.start_pos.y)
            if sx and not self._stroke_pending then
                self._stroke_pending = { x = sx, y = sy, micro = {} }
            end
        end
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        if x then
            if self._stroke then
                self:_extendStroke(x, y)
            elseif self._stroke_pending then
                local p = self._stroke_pending
                -- 微轨迹尽早记录:只要 pan 事件到达、与末点不同就记(哪怕仍在 PAN
                -- 死区内),保住起笔处的弧线信息,起笔时作为完整起始路径渲染
                local last_micro = p.micro[#p.micro] or p
                if #p.micro < 32 and (x ~= last_micro.x or y ~= last_micro.y) then
                    p.micro[#p.micro + 1] = { x = x, y = y }
                end
                -- 早触发:移动超过 EARLY_TRIGGER 阈值即正式起笔;阈值越小起笔越早,
                -- 起笔小圆弧越早进入 Catmull-Rom 渲染而保留曲率(设 0=首点即起笔)
                if math.abs(x - p.x) >= const.STROKE_EARLY_TRIGGER_DIST
                    or math.abs(y - p.y) >= const.STROKE_EARLY_TRIGGER_DIST then
                    -- 移动超过阈值:起笔 = 按下点 + 微轨迹 + 当前点,一次成形
                    self._stroke_pending = nil
                    local points = { { x = p.x, y = p.y } }
                    for _, mp in ipairs(p.micro) do
                        points[#points + 1] = mp
                    end
                    self._stroke = {
                        kind = "freehand",
                        points = points,
                        gray = self:_resolveGray(),
                        alpha = self:_resolveAlpha(),
                        -- 描边填:描边固定 1px(只界定区域,不随粗细设置)
                        width = (self.tool == "fill") and 1 or self:_resolveWidth(),
                        tip = self.tip,
                    }
                    -- 起笔:先把已画内容(起笔圆点/刚渲染出的首段)的包围盒并入累积区域,
                    -- 再"立即刷新第一段"(不等节流窗口,减少起笔延迟感=跟手优化)。
                    -- 区域必须在这里合并:缺了它,下面那发没有区域的
                    -- setDirty(partial, nil) 在 KOReader 里就是整屏刷新 —— 真机上
                    -- 表现为"快速起笔闪一下"(慢起笔由 onHold 起笔,那边有 if rx0 守卫)
                    local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
                    if rx0 then
                        self._stroke_region = self:_mergeRegions(self._stroke_region,
                            self:_dirtyRegion(rx0, ry0, rx1, ry1,
                                (self._stroke and self._stroke.width or 2) + 2))
                    end
                    self:_extendStroke(x, y)
                    self:_flushStrokeRepaint()
                end
            end
        end
    elseif tool == "line" or tool == "rect" or tool == "circle" then
        -- 图形工具:拖动只记录锚点与当前点,不逐帧预览跟随轨迹;
        -- 形状在收笔时用最后更新的点一次确认(加快显示)
        self:_trackShapeAnchor(ges)
    elseif tool == "select" then
        -- 先点选再拖动:有选中对象时按下,先判定是否命中变形锚点;
        -- 命中锚点 → 变形(缩放/旋转),否则记录拖动起点(松手移动/复制)
        if self._selected and not self._select_drag and not self._transform then
            local sx, sy = self:_toCanvas(
                ges.start_pos and ges.start_pos.x or ges.pos.x,
                ges.start_pos and ges.start_pos.y or ges.pos.y)
            if sx then
                local handle = self:_hitHandle(sx, sy)
                if handle then
                    local el = self._selected
                    local b = el._bbox or self:_elementBBox(el)
                    self._transform = {
                        handle = handle,
                        x0 = sx, y0 = sy,
                        bbox = { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 },
                        old_region = self:_elementRegion(el),
                        orig = self:_cloneElement(el),
                    }
                else
                    self._select_drag = { x0 = sx, y0 = sy }
                end
            end
        elseif self._select_drag and not self._transform then
            -- 拖动中:更新 0.5s 停留落点预览(停止防抖,显示后跟随手指实时更新)
            local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
            if x then
                self:_scheduleDragPreview(x, y)
            end
        elseif self._transform then
            -- 拖锚点变形(旋转/缩放):停满 0.5s 显示预览,随后跟随手指实时更新(节流防抖)
            local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
            if x then
                self:_scheduleDragPreview(x, y)
            end
        end
    end
    return true
end

-- v61r:抬笔自动刷新(全工具):收笔提交后自动补一次全画布 partial(局部快速波形,
-- 不闪屏);v61s 按用户要求由 full 改 partial——只驱动变化像素、无全刷黑闪,
-- 同时把绘制期间逐段 partial 堆积的残影整幅匀平;未提交墨迹的手势不触发
function M:_penUpRefresh()
    UIManager:setDirty(self, "partial")
end

function M:onPanRelease(_, ges)
    local committed = false -- 本次手势是否提交了墨迹/对象变更(决定是否抬笔全刷)
    if self._stroke then
        if ges and ges.pos then
            local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
            if x then
                self:_finishStroke(x, y)
            else
                self:_finishStroke(nil)
            end
        else
            self:_finishStroke(nil)
        end
        committed = true
    elseif self._stroke_pending then
        -- 移动未达防抖阈值就松手:有多个微轨迹点(防抖期内画出的小弧)按完整
        -- 轨迹提交短笔画,起笔处的小圆弧不再丢;单点/无微轨迹 = 快速轻触,仍出墨点
        local p = self._stroke_pending
        self._stroke_pending = nil
        if #p.micro >= 2 then
            local points = { { x = p.x, y = p.y } }
            for _, mp in ipairs(p.micro) do
                points[#points + 1] = mp
            end
            self._stroke = {
                kind = "freehand",
                points = points,
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(),
                width = (self.tool == "fill") and 1 or self:_resolveWidth(),
                tip = self.tip,
            }
            local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
            if rx0 then
                self._stroke_region = self:_mergeRegions(self._stroke_region,
                    self:_dirtyRegion(rx0, ry0, rx1, ry1, self._stroke.width + 2))
            end
            self:_finishStroke(nil)
        else
            self:_commitDot(p.x, p.y)
        end
        committed = true
    elseif self._shape_start then
        -- 图形工具 / 矩形框擦:用最后更新的点一次确认
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        if self.tool == "eraser" then
            self:_commitEraseRect(x, y)
        else
            self:_commitShape(x, y)
        end
        committed = true
    elseif self._erase_path then
        -- 画笔擦:删除与路径包围盒相交的对象
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        self:_commitErasePath(x, y)
        committed = true
    elseif self._transform then
        -- 选择工具变形:按锚点拖拽 缩放/旋转 选中对象
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        self:_finishTransform(x, y)
        committed = true
    elseif self._select_drag then
        -- 选择工具:松手按 终点-起点 位移 移动/复制 选中对象
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        self:_finishSelectDrag(x, y)
        committed = true
    elseif self.tool == "fill" and self.fill_mode == "tap" then
        -- 点填:手势被分类成 pan/hold 时(tap 有轻微位移/停留)在释放点填充——
        -- onTap 只覆盖纯 tap 分类,否则"点填偶发没反应"
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        if x then
            self:_fillAt(x, y)
            committed = true
        end
    end
    if committed then
        self:_penUpRefresh()
    end
    return true
end

-- 双指手势忽略(不画、不冲突);但会打断进行中的笔画且之后可能不再收 pan_release,
-- 这里按末点收笔,防止下一笔起笔连接上一笔末笔
function M:onTwoFingerPan()
    self:_finishStroke(nil)
    self:_penUpRefresh()
    return true
end

function M:onPinch()
    self:_finishStroke(nil)
    self:_penUpRefresh()
    return true
end

-- 快速拖动被判定为 swipe(不是 pan):图形工具按 起点→终点 一次确认,
-- 画笔/橡皮画一条快速直线,避免"快画没反应"。
-- 注意:swipe 的 pos = 起点,end_pos = 终点(与 pan 语义相反)。
function M:onSwipe(_, ges)
    if not ges or not ges.pos then
        return true
    end
    -- 上一手势可能以 swipe 收尾(pan_release 未触发):图形/橡皮清理遗留锚点,
    -- 画笔的进行中笔画在下方按终点收笔(不丢弃、不连笔)
    local pending = self._stroke_pending -- 先捕获:防抖期微轨迹在下方画笔分支复用
    self:_invalidateTasks()
    self._shape_start = nil
    self._erase_path = nil
    self._stroke_pending = nil
    self._select_drag = nil
    self._transform = nil
    self:_cancelShapePreview()
    self._shape_preview_region = nil
    self._shape_pos = nil
    local in_progress_stroke = self._stroke
    local px, py = ges.pos.x, ges.pos.y
    local ex = (ges.end_pos and ges.end_pos.x) or px
    local ey = (ges.end_pos and ges.end_pos.y) or py
    local sx, sy = self:_toCanvas(px, py)
    local x, y = self:_toCanvas(ex, ey)
    if not (sx and x) then
        -- swipe 起点/终点在画布外:仍要收笔进行中的描边路径,
        -- 否则填充延迟到下一次操作起笔(跨手势保护)才触发
        if in_progress_stroke then
            self:_finishStroke(nil)
            self:_penUpRefresh()
        end
        return true
    end
    local tool = self.tool
    local committed = false
    if tool == "line" or tool == "rect" or tool == "circle" then
        -- 图形工具:起点=锚点,终点=swipe 终点,一次确认
        self._shape_start = { x = sx, y = sy }
        self:_commitShape(x, y)
        committed = true
    elseif tool == "eraser" then
        -- 橡皮:快速拖动删除与 起点→终点 包围盒相交的对象
        self:_eraseInRect(math.min(sx, x), math.min(sy, y), math.max(sx, x), math.max(sy, y))
        committed = true
    elseif tool == "fill" and self.fill_mode == "tap" then
        -- 点填:快速点按被判定为 swipe 时,在终点填充(防"点填偶发没反应")
        self:_fillAt(x, y)
        committed = true
    elseif tool == "brush" or (tool == "fill" and self.fill_mode == "path") then
        if in_progress_stroke then
            -- 快速收尾:把进行中的笔画在终点收笔,避免丢弃/连笔;
            -- 描边填路径即使以 swipe 收尾也由 _finishStroke 内部闭合填充
            self:_finishStroke(x, y)
            committed = true
        elseif pending and #(pending.micro or {}) >= 1 then
            -- 防抖期已记录微轨迹(快速小弧未达起笔阈值就被分类为 swipe):
            -- 按下点 + 微轨迹 + 终点 构成完整路径落盘,起笔小圆弧的曲率保留
            -- (旧版只画首尾直线把弧拉直)。描边填同样适用:_finishStroke 内部
            -- 闭合填充,退化路径自动清除路径墨迹不留残迹
            local points = { { x = pending.x, y = pending.y } }
            for _, mp in ipairs(pending.micro) do
                points[#points + 1] = mp
            end
            local last_m = points[#points]
            if last_m.x ~= x or last_m.y ~= y then
                points[#points + 1] = { x = x, y = y }
            end
            self._stroke = {
                kind = "freehand",
                points = points,
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(),
                width = (tool == "fill") and 1 or self:_resolveWidth(),
                tip = self.tip,
            }
            local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
            if rx0 then
                self._stroke_region = self:_mergeRegions(self._stroke_region,
                    self:_dirtyRegion(rx0, ry0, rx1, ry1, self._stroke.width + 2))
            end
            self:_finishStroke(nil)
            committed = true
        else
            if tool == "fill" then
                -- 纯快速描边填:swipe 只有首尾 2 点,无法界定闭合区域,直接忽略
                return true
            end
            -- 纯快速直线
            local stroke = {
                kind = "freehand",
                points = { { x = sx, y = sy }, { x = x, y = y } },
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(),
                width = self:_resolveWidth(),
                tip = self.tip,
            }
            shapes.thickLine(self:_alphaBB(self.canvas_bb, stroke), sx, sy, x, y,
                stroke.width, Blitbuffer.gray(stroke.gray), stroke.tip)
            table.insert(self.elements, stroke)
            self:_cacheBBox(stroke)
            self:_pushUndo({ kind = "add", el = stroke })
            self:_clearRedo()
            self:_log("commit swipe stroke", tool)
            UIManager:setDirty(self, "partial", self:_dirtyRegion(sx, sy, x, y, stroke.width + 2))
            committed = true
        end
    elseif tool == "select" then
        -- 选择工具快速拖动:按 起点→终点 位移 移动/复制 选中对象
        self:_applySelectDelta(math.floor(x - sx + 0.5), math.floor(y - sy + 0.5))
        committed = true
    end
    if committed then
        self:_penUpRefresh()
    end
    return true
end

-- multiswipe(快速甩动轨迹有方向变化时替代 swipe):复用 swipe 逻辑收笔,
-- 否则描边填/画笔的进行中笔画收不到收尾事件而残留(被 stop_events_propagation 吞掉)
function M:onMultiSwipe(_, ges)
    return self:onSwipe(nil, ges)
end

-- 收笔前短暂停留会被判定为 hold 系手势(hold_pan/hold_release)而非 pan/pan_release;
-- 统一转发到 pan 逻辑,保证上一笔落盘、下一笔不连笔
function M:onHoldPan(_, ges)
    return self:onPan(nil, ges)
end

function M:onHoldRelease(_, ges)
    return self:onPanRelease(nil, ges)
end

-- 按住未动(hold 手势,KOREADER 阈值 0.5s):
-- 画笔:起笔停留 ≥0.5s 显示起点(圆点)——创建进行中笔画、画出起点但不提交,
-- 继续拖动(hold_pan)扩展同一条笔画,松手收笔整体落盘(不拖则成单个圆点);
-- 已有进行中笔画则先在停留点收笔
function M:onHold(_, ges)
    if self._stroke then
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        self:_finishStroke(x, y)
    elseif (self.tool == "brush" or (self.tool == "fill" and self.fill_mode == "path"))
        and ges and ges.pos then
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        if x then
            -- 起笔停留:按下点(pending)转正式笔画,无 pending 用停留点。
            -- 防抖期已记录的微轨迹一并带入(起笔小弧保留),创建进行中笔画并
            -- 渲染已有点(单点=起点圆点,不提交到元素栈);后续 hold_pan 拖动
            -- 扩展同一条笔画,收笔整体落盘
            local p = self._stroke_pending or { x = x, y = y, micro = {} }
            self._stroke_pending = nil
            local points = { { x = p.x, y = p.y } }
            for _, mp in ipairs(p.micro or {}) do
                points[#points + 1] = mp
            end
            self._stroke = {
                kind = "freehand",
                points = points,
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(),
                -- 描边填:描边固定 1px(只界定区域,不随粗细设置)
                width = (self.tool == "fill") and 1 or self:_resolveWidth(),
                tip = self.tip,
            }
            local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
            if rx0 then
                self._stroke_region = self:_mergeRegions(self._stroke_region,
                    self:_dirtyRegion(rx0, ry0, rx1, ry1, self._stroke.width + 2))
                self:_flushStrokeRepaint()
            end
        end
    end
    return true
end

-- 起笔死区调优(v56/v56b):手势检测层按下后要移够 PAN_THRESHOLD 才发第一个 pan
-- 事件(死区内弧线信息从源头丢失=起笔画不了曲线的主因);手不动满 hold 间隔才发
-- hold(慢起笔白等 0.5s)。画板打开期间把 GestureDetector 实例的两项动态调整:
--   PAN_THRESHOLD → scaleByDPI(GESTURE_PAN_THRESHOLD_DP)
--   ges_hold_interval → 按比例缩放(GESTURE_HOLD_INTERVAL_MS/500,不依赖 time 模块/单位)
-- 关闭时还原。不改 KOReader 源码、不影响画板以外的手势行为。
-- require 放方法内(pcall 保护),避免 headless 测试 / wbuilder 场景下的加载顺序问题
function M:_applyGestureTuning()
    local ok, gd = pcall(function()
        local Device = require("device")
        return Device.input and Device.input.gesture_detector or nil
    end)
    if not ok or not gd then return end
    -- 幂等:重复调用不覆盖已保存的原值(否则二次应用会把"已调整值"当原值存下)
    if gd._drawingpad_orig_pan_threshold == nil and gd._drawingpad_orig_hold_interval == nil then
        if type(gd.PAN_THRESHOLD) == "number" and gd.screen and gd.screen.scaleByDPI then
            gd._drawingpad_orig_pan_threshold = gd.PAN_THRESHOLD
            gd.PAN_THRESHOLD = gd.screen:scaleByDPI(const.GESTURE_PAN_THRESHOLD_DP)
        end
        if type(gd.ges_hold_interval) == "number" and gd.ges_hold_interval > 0 then
            gd._drawingpad_orig_hold_interval = gd.ges_hold_interval
            gd.ges_hold_interval = gd.ges_hold_interval
                * (const.GESTURE_HOLD_INTERVAL_MS / 500)
        end
    end
end

function M:_restoreGestureTuning()
    local ok, gd = pcall(function()
        local Device = require("device")
        return Device.input and Device.input.gesture_detector or nil
    end)
    if not ok or not gd then return end
    if gd._drawingpad_orig_pan_threshold ~= nil then
        gd.PAN_THRESHOLD = gd._drawingpad_orig_pan_threshold
        gd._drawingpad_orig_pan_threshold = nil
    end
    if gd._drawingpad_orig_hold_interval ~= nil then
        gd.ges_hold_interval = gd._drawingpad_orig_hold_interval
        gd._drawingpad_orig_hold_interval = nil
    end
end

return M
