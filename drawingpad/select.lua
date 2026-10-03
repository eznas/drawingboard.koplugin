--[[--
drawingpad.select — 选择对象(移动/复制)与变形(缩放/旋转锚点)方法(DrawingCanvas 混合模块)。
--]]

local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local const = require("drawingpad.const")

local M = {}

-- ============================ 选择对象(移动/复制) ============================

-- 长按选择按钮:切换 移动/复制 模式(按钮文字与状态栏跟随)
function M:_toggleSelectMode()
    self.select_mode = (self.select_mode == "move") and "copy" or "move"
    self:_syncToolLabels()
    self:_log("select_mode ->", self.select_mode)
    self:_updateStatus()
end

-- 设置/清除选中对象(更新高亮刷新区域)。
-- 选中对象变化时锚点回到缩放模式(再次点选同一对象才切换 缩放/旋转)
function M:_setSelected(el)
    if self._selected == el then
        return
    end
    local old = self._selected
    self._selected = el
    self._handle_mode = "scale"
    local region = nil
    if old then
        region = self:_mergeRegions(region, self:_elementRegion(old))
    end
    if el then
        region = self:_mergeRegions(region, self:_elementRegion(el))
    end
    UIManager:setDirty(self, "partial", region)
end

-- 选中锚点完整刷新区域:bbox 外扩 手柄半宽+pad(约 12px),保证切换 缩放/旋转 样式时
-- 锚点像素一并刷新(_elementRegion 只盖 bbox±4,画锚点会留残影)
function M:_handleRegion(el)
    local b = el._bbox or self:_elementBBox(el)
    if not b then
        return nil
    end
    local margin = 4 + Screen:scaleBySize(6) + 2
    local rx0 = math.max(0, math.floor(b.x0) - margin)
    local ry0 = math.max(0, math.floor(b.y0) - margin)
    local rx1 = math.min(self.canvas_w, math.ceil(b.x1) + margin)
    local ry1 = math.min(self.canvas_h, math.ceil(b.y1) + margin)
    if rx1 <= rx0 or ry1 <= ry0 then
        return nil
    end
    return Geom:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 }
end

-- 按位移应用 移动/复制(选择工具收笔与快速拖动共用)
function M:_applySelectDelta(dx, dy)
    local el = self._selected
    if not el or (dx == 0 and dy == 0) then
        return
    end
    if self.select_mode == "copy" then
        -- 复制:克隆→平移→入栈,原对象不动
        local copy = self:_cloneElement(el)
        self:_moveElement(copy, dx, dy)
        table.insert(self.elements, copy)
        self:_cacheBBox(copy)
        self:_pushUndo({ kind = "add", el = copy })
        self:_clearRedo()
        local region = self:_elementRegion(copy)
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
        self:_log("select copy", el.kind, dx, dy)
    else
        -- 移动:旧区域先记录,平移后重绘 旧∪新(旧区域底层墨迹恢复)
        local old_region = self:_elementRegion(el)
        self:_moveElement(el, dx, dy)
        self:_cacheBBox(el)
        local region = self:_mergeRegions(old_region, self:_elementRegion(el))
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
        self:_pushUndo({ kind = "move", el = el, dx = dx, dy = dy })
        self:_clearRedo()
        self:_log("select move", el.kind, dx, dy)
    end
end

-- 选择工具收笔:按 拖动终点-起点 位移 移动/复制 选中对象。
-- 先取消预览并擦除其累积区域(预览跟随期间中间位置需一并刷新,防残留)
function M:_finishSelectDrag(x, y)
    self:_cancelDragPreview()
    local prev_region = self._drag_preview_region
    self._drag_preview_region = nil
    local drag = self._select_drag
    self._select_drag = nil
    if not (drag and x) then
        -- 未成移动(松手在画布外等):擦除已显示的预览残留
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    self:_applySelectDelta(math.floor(x - drag.x0 + 0.5), math.floor(y - drag.y0 + 0.5))
    if prev_region then
        UIManager:setDirty(self, "partial", prev_region)
    end
end

-- ============================ 拖拽预览(移动/旋转/缩放) ============================
-- 两段式:①手指停满 MOVE_PREVIEW_DELAY(0.2s,全对象统一含文字)才首次显示(停止位置防抖);
-- ②一旦显示,后续 pan 跟随手指实时更新(不再随移动擦除,消除闪烁抖动),
-- 重绘按 DRAG_PREVIEW_REFRESH_INTERVAL 节流合并区域(墨水屏不逐事件刷新防卡顿)。
-- 拖本体 → 落点预览;旋转模式拖锚点 → 旋转预览;缩放模式拖锚点 → 拉伸预览。

-- 每次 pan 调用:预览未显示则重排首次显示定时器;已显示则实时跟随更新
function M:_scheduleDragPreview(x, y)
    if self._drag_preview then
        self:_updateDragPreview(x, y)
        return
    end
    if self._drag_preview_fn then
        UIManager:unschedule(self._drag_preview_fn)
        self._drag_preview_fn = nil
    end
    self._drag_preview_pos = { x = x, y = y }
    local fn = function()
        self:_maybeShowDragPreview()
    end
    self._drag_preview_fn = fn
    UIManager:scheduleIn(const.MOVE_PREVIEW_DELAY, fn)
end

-- 按当前拖拽类型构建预览元素(选中对象克隆+变形),无变化返回 nil。
-- 旋转/缩放/移动的数学与提交时(_finishTransform/_applySelectDelta)完全一致,所见即提交
function M:_buildDragPreview(x, y)
    local el = self._selected
    if not el then
        return nil
    end
    local pv
    local tr = self._transform
    if tr and self._handle_mode == "rotate" then
        local sb = tr.bbox
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        local a0 = math.atan2(tr.y0 - cy, tr.x0 - cx)
        local a1 = math.atan2(y - cy, x - cx)
        if math.abs(a1 - a0) < 0.02 then
            return nil -- 角度几乎未变
        end
        pv = self:_cloneElement(el)
        self:_rotateElement(pv, a1 - a0, cx, cy)
    elseif tr then
        -- 缩放:旋转形状按 OBB 两轴缩放,其余按锚点拖到当前位置算新包围盒
        pv = self:_cloneElement(el)
        if not self:_scaleElementOriented(pv, tr.handle, x, y) then
            local sb = tr.bbox
            local nb = self:_transformBBox(tr.handle, sb, x, y)
            if nb.x0 == sb.x0 and nb.y0 == sb.y0 and nb.x1 == sb.x1 and nb.y1 == sb.y1 then
                return nil -- 尺寸未变
            end
            self:_scaleElement(pv, sb, nb)
        end
    else
        local drag = self._select_drag
        if not drag then
            return nil
        end
        local dx = math.floor(x - drag.x0 + 0.5)
        local dy = math.floor(y - drag.y0 + 0.5)
        if dx == 0 and dy == 0 then
            return nil -- 未位移
        end
        pv = self:_cloneElement(el)
        self:_moveElement(pv, dx, dy)
    end
    return pv
end

-- 首次显示定时器到点:构建并立即刷新预览
function M:_maybeShowDragPreview()
    self._drag_preview_fn = nil
    if not self.canvas_bb then
        return -- 关闭后挂起的回调:直接丢弃
    end
    local pos = self._drag_preview_pos
    if not pos then
        return
    end
    local pv = self:_buildDragPreview(pos.x, pos.y)
    if not pv then
        return
    end
    self:_cacheBBox(pv)
    -- 记录首次显示的旋转角,作为后续跟随重建的节流基准
    local tr = self._transform
    if tr and self._handle_mode == "rotate" then
        local sb = tr.bbox
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        self._drag_preview_angle = math.atan2(pos.y - cy, pos.x - cx)
    end
    self._drag_preview = pv
    self._drag_preview_region = self:_elementRegion(pv)
    local el = self._selected
    self:_log("drag preview shown", el and el.kind,
        self._transform and (self._handle_mode == "rotate" and "rotate" or "scale") or "move")
    UIManager:setDirty(self, "partial", self._drag_preview_region)
end

-- 预览已显示后:跟随手指更新预览元素,区域并入累积区,节流重绘。
-- bbox 与当前预览一致(几何未变,如微动/圆旋转)则跳过,不重复刷新=防闪烁、省波形。
-- 旋转预览额外按角度节流重建:每次 pan 全量重栅格化(大 fill 数毫秒到数百毫秒)是
-- 拖拽卡断主因,角度变化小于 DRAG_ROTATE_RECALC_ANGLE 直接跳过(只更新落点位置)
function M:_updateDragPreview(x, y)
    self._drag_preview_pos = { x = x, y = y }
    if not self._drag_preview then
        return
    end
    local tr = self._transform
    if tr and self._handle_mode == "rotate" then
        local sb = tr.bbox
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        local a = math.atan2(y - cy, x - cx)
        local last = self._drag_preview_angle
        if last and math.abs(a - last) < const.DRAG_ROTATE_RECALC_ANGLE then
            return -- 角度几乎未变:跳过重建与重绘
        end
        self._drag_preview_angle = a
    end
    local pv = self:_buildDragPreview(x, y)
    if not pv then
        return
    end
    self:_cacheBBox(pv)
    local cur = self._drag_preview
    if cur._bbox and pv._bbox
        and cur._bbox.x0 == pv._bbox.x0 and cur._bbox.y0 == pv._bbox.y0
        and cur._bbox.x1 == pv._bbox.x1 and cur._bbox.y1 == pv._bbox.y1 then
        return -- 可见结果未变,不重绘
    end
    self._drag_preview = pv
    self._drag_preview_region = self:_mergeRegions(self._drag_preview_region, self:_elementRegion(pv))
    if not self._drag_preview_repaint_pending then
        self._drag_preview_repaint_pending = true
        local fn = function()
            self:_flushDragPreviewRepaint()
        end
        self._drag_preview_repaint_fn = fn
        UIManager:scheduleIn(const.DRAG_PREVIEW_REFRESH_INTERVAL, fn)
    end
end

-- 预览跟随节流窗口到点:合并累积区域刷新
function M:_flushDragPreviewRepaint()
    if self._drag_preview_repaint_fn then
        UIManager:unschedule(self._drag_preview_repaint_fn)
        self._drag_preview_repaint_fn = nil
    end
    self._drag_preview_repaint_pending = false
    if not self.canvas_bb then
        return -- 关闭后挂起的回调:直接丢弃
    end
    local reg = self._drag_preview_region
    self._drag_preview_region = nil
    if reg then
        UIManager:setDirty(self, "partial", reg)
    end
end

-- 取消预览定时器与节流任务,清除预览元素(累积区域保留供收笔刷新擦除)
function M:_cancelDragPreview()
    if self._drag_preview_fn then
        UIManager:unschedule(self._drag_preview_fn)
        self._drag_preview_fn = nil
    end
    if self._drag_preview_repaint_fn then
        UIManager:unschedule(self._drag_preview_repaint_fn)
        self._drag_preview_repaint_fn = nil
    end
    self._drag_preview_repaint_pending = false
    self._drag_preview = nil
    self._drag_preview_angle = nil
end

-- ============================ 选中对象 灰度/粗细 调节 ============================

-- 调整选中对象的灰度(0-1):可撤销,重绘受影响区域。
-- no_undo=true 供直接调节弹窗逐 tick 调用(关闭时统一写一条撤销)
function M:_applySelectedGray(v, no_undo)
    local el = self._selected
    if not el then
        return
    end
    local g = v / 100
    if math.abs((el.gray or 1) - g) < 0.001 then
        return -- 值未变不产生记录
    end
    local orig = self:_cloneElement(el)
    el.gray = g
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    -- 灰度突变用 ui 波形清 EPD 残影(partial 会留旧灰度,滑块逐 tick 时可见)
    UIManager:setDirty(self, "ui", region)
    if not no_undo then
        self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
        self:_clearRedo()
        self:_log("set selected gray", el.kind, v)
    end
end

-- 调整选中对象的线宽(px):可撤销。线宽影响包围盒,需按 旧∪新 区域重绘。
-- no_undo=true 供直接调节弹窗逐 tick 调用(关闭时统一写一条撤销)
function M:_applySelectedWidth(v, no_undo)
    local el = self._selected
    if not el or el.kind == "text" then
        return -- 文字无线宽
    end
    if el.width == v then
        return
    end
    local old_region = self:_elementRegion(el)
    local orig = self:_cloneElement(el)
    el.width = v
    self:_cacheBBox(el)
    local region = self:_mergeRegions(old_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    -- 同灰度:粗细变化用 ui 波形清残影(partial 会留旧宽度轮廓)
    UIManager:setDirty(self, "ui", region)
    if not no_undo then
        self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
        self:_clearRedo()
        self:_log("set selected width", el.kind, v)
    end
end

-- 调整选中对象的透明度(0-100,100=不透明):可撤销,重绘受影响区域。
-- no_undo=true 供直接调节弹窗逐 tick 调用(关闭时统一写一条撤销)
function M:_applySelectedAlpha(v, no_undo)
    local el = self._selected
    if not el then
        return
    end
    local a = v / 100
    if math.abs((el.alpha or 1) - a) < 0.001 then
        return -- 值未变不产生记录
    end
    local orig = self:_cloneElement(el)
    el.alpha = a
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    -- 同灰度:透明度变化用 ui 波形清 EPD 残影(partial 会留旧灰度,滑块逐 tick 时可见)
    UIManager:setDirty(self, "ui", region)
    if not no_undo then
        self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
        self:_clearRedo()
        self:_log("set selected alpha", el.kind, v)
    end
end

-- ============================ 变形(缩放/旋转锚点) ============================

-- 选中框四角(锚点位置):倾斜椭圆(rot≠0)/旋转矩形(poly)用对象自身的旋转外接框(OBB)
-- 紧贴边界,避免轴对齐 AABB 四角悬空一大圈;其余对象用轴对齐外接框+pad。
-- 命中测试与锚点绘制共用同一组角点,保证"所见即所点"
function M:_frameCorners(el)
    local pad = 4
    if el.kind == "circle" and (el.rot or 0) ~= 0 then
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local c, s = math.cos(el.rot), math.sin(el.rot)
        -- 椭圆 OBB 四角 = 中心 ± rx·u ± ry·v(u/v 为旋转后的两轴)
        local pts = {
            { x = el.cx + rx * c - ry * s, y = el.cy + rx * s + ry * c },
            { x = el.cx + rx * c + ry * s, y = el.cy + rx * s - ry * c },
            { x = el.cx - rx * c + ry * s, y = el.cy - rx * s - ry * c },
            { x = el.cx - rx * c - ry * s, y = el.cy - rx * s + ry * c },
        }
        -- 沿径向外扩 pad(锚点略微悬空于椭圆外)
        for _, p in ipairs(pts) do
            local dx, dy = p.x - el.cx, p.y - el.cy
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                p.x = p.x + dx / len * pad
                p.y = p.y + dy / len * pad
            end
        end
        return pts
    elseif el.kind == "poly" then
        -- 旋转矩形转 poly:取其角点,绕质心外扩 pad
        local pts = {}
        local cx, cy = 0, 0
        for i, p in ipairs(el.points) do
            pts[i] = { x = p.x, y = p.y }
            cx, cy = cx + p.x, cy + p.y
        end
        cx, cy = cx / #pts, cy / #pts
        for _, p in ipairs(pts) do
            local dx, dy = p.x - cx, p.y - cy
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                p.x = p.x + dx / len * pad
                p.y = p.y + dy / len * pad
            end
        end
        return pts
    elseif el.kind == "text" and (el.rot or 0) ~= 0 then
        -- 旋转文字:4 个渲染角绕锚点旋转(与包围盒同数学),沿径向外扩 pad。
        -- 旋转中心 = 基线左端(_drawTextTo 变换分支同锚点:基线 = el.y + 0.8*字号),
        -- 否则选取框绕 el.y 转、渲染绕基线转,旋转后错位 0.8*字号
        local e = self:_textExtent(el)
        if not e then
            return nil
        end
        local ax = el.x or 0
        local ay = e.baseline
        local c, sn = math.cos(el.rot), math.sin(el.rot)
        local pts = {}
        local corners = {
            { ax - 1, e.baseline - e.yt - 1 },
            { ax + e.w + 1, e.baseline - e.yt - 1 },
            { ax + e.w + 1, e.baseline + e.yb + 1 },
            { ax - 1, e.baseline + e.yb + 1 },
        }
        for i, co in ipairs(corners) do
            local dx, dy = co[1] - ax, co[2] - ay
            local px, py = ax + dx * c - dy * sn, ay + dx * sn + dy * c
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                px = px + dx / len * pad
                py = py + dy / len * pad
            end
            pts[i] = { x = px, y = py }
        end
        return pts
    end
    local b = el._bbox or self:_elementBBox(el)
    if not b then
        return nil
    end
    return {
        { x = b.x0 - pad, y = b.y0 - pad },
        { x = b.x1 + pad, y = b.y0 - pad },
        { x = b.x1 + pad, y = b.y1 + pad },
        { x = b.x0 - pad, y = b.y1 + pad },
    }
end

-- 命中选中对象的四角变形锚点;返回锚点名(nw/ne/se/sw)或 nil。
-- 缩放/旋转共用同一组四角:再次点选切换 _handle_mode,拖动时按模式分流(见 _finishTransform)。
-- 文字不支持旋转(再次点选不切换),但缩放四角照常命中
function M:_hitHandle(x, y)
    local el = self._selected
    if not el then
        return nil
    end
    local pts = self:_frameCorners(el)
    if not pts then
        return nil
    end
    local ids = { "nw", "ne", "se", "sw" }
    local radius = (el.kind == "text")
        and const.TEXT_HANDLE_HIT_RADIUS or const.HANDLE_HIT_RADIUS
    for i, p in ipairs(pts) do
        if math.abs(x - p.x) <= radius and math.abs(y - p.y) <= radius then
            return ids[i]
        end
    end
    return nil
end

-- 选择工具变形收笔:按锚点拖拽应用 缩放/旋转 到选中对象(可撤销)。
-- 同一组四角锚点:_handle_mode=="rotate" 时拖角绕包围盒中心旋转,否则按对角缩放。
-- 先取消预览并擦除其累积区域(跟随期间中间位置需一并刷新,防残留)
function M:_finishTransform(x, y)
    self:_cancelDragPreview()
    local prev_region = self._drag_preview_region
    self._drag_preview_region = nil
    local tr = self._transform
    self._transform = nil
    if not (tr and x) then
        -- 未成变形(松手在画布外等):擦除已显示的预览残留
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    local el = self._selected
    if not el then
        return
    end
    local sb = tr.bbox
    if self._handle_mode == "rotate" then
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        local a0 = math.atan2(tr.y0 - cy, tr.x0 - cx)
        local a1 = math.atan2(y - cy, x - cx)
        self:_rotateElement(el, a1 - a0, cx, cy)
    else
        -- 旋转形状(锚在 OBB 角上)按自身两轴缩放,否则 AABB 角锚路径
        if not self:_scaleElementOriented(el, tr.handle, x, y) then
            local nb = self:_transformBBox(tr.handle, sb, x, y)
            self:_scaleElement(el, sb, nb)
        end
    end
    self:_cacheBBox(el)
    local region = self:_mergeRegions(tr.old_region, self:_elementRegion(el))
    if prev_region then
        -- 预览跟随期间累积的中间位置残影一并白刷+刷新:
        -- 漏并则松手后残留多个角度的 fill 影(横纹,拉伸预览区域更大更明显)
        region = self:_mergeRegions(region, prev_region)
    end
    self:_pushUndo({ kind = "transform", el = el, orig = tr.orig, final = self:_cloneElement(el) })
    self:_clearRedo()
    self:_redrawRegion(region)
    -- 旋转/缩放是灰色大区域内容突变,EPD partial 刷新会残留灰度条纹(横纹,拉伸更大更明显);
    -- 用 "ui" 波形刷新一次清除残影
    UIManager:setDirty(self, "ui", region)
    self:_log("transform", tr.handle)
end

return M
