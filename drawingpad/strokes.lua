--[[--
drawingpad.strokes — 画笔/橡皮/图形工具与刷新节流方法(DrawingCanvas 混合模块)。
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

-- 作废所有挂起的定时任务(关闭/切工具/最小化/清空时调用)。
-- scheduleIn 返回 nil 取不到句柄,但 UIManager:unschedule 按闭包引用取消,
-- 这里对保存下来的同一个闭包调用 unschedule 即真正从任务队列移除,
-- 杜绝"关闭后僵尸定时器仍触发"的隐患
function M:_invalidateTasks()
    if self._stroke_repaint_fn then
        UIManager:unschedule(self._stroke_repaint_fn)
        self._stroke_repaint_fn = nil
    end
    if self._shape_preview_fn then
        UIManager:unschedule(self._shape_preview_fn)
        self._shape_preview_fn = nil
    end
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
    self._drag_preview_region = nil
    self._stroke_repaint_pending = false
    self._stroke_region = nil
end

-- 增量样条渲染:消费 points 里尚未渲染的段(_seg 计数),画法与 shapes.polyline
-- 逐段一致(Catmull-Rom 过点插值)。段 P_k→P_{k+1} 需要邻点 P_{k-1}/P_{k+2} 定切向,
-- 故滞后一点渲染(末段由 _renderStrokeClose 收笔时补齐),
-- 保证实时笔迹与撤销/保存重绘完全相同。返回本次绘制内容的包围盒(无则 nil)。
function M:_renderStrokeTail(s)
    s = s or self._stroke
    if not s then return nil end
    local pts = s.points
    local n = #pts
    if n == 0 then return nil end
    local gray = Blitbuffer.gray(s.gray)
    -- 半透明笔画:实时增量也走混合代理,与提交后重绘同一数学(自交叉处实时会加深,
    -- 收笔层序重放后均匀——已知轻微跳变)
    local pbb = self:_alphaBB(self.canvas_bb, s)
    local minx, miny, maxx, maxy
    if not s._tip_drawn then
        -- 起点全宽笔触(按下即见;起笔即全宽,起笔处的小圆弧清晰可见)。
        -- 它的范围也计入返回值:调用方靠这个包围盒并入 _stroke_region —— 只画了起笔
        -- 圆点、还没到能渲染线段(需右邻点)的那次调用曾返回 nil,于是"起笔立即刷新"
        -- 那发 setDirty(partial, nil) = 整屏刷新 = 快速起笔闪屏(慢起笔走 onHold,
        -- 有 `if rx0 then` 守卫,所以不闪)
        s._tip_drawn = true
        shapes.tip(pbb, pts[1].x, pts[1].y, s.width, gray, s.tip)
        minx, maxx = pts[1].x, pts[1].x
        miny, maxy = pts[1].y, pts[1].y
    end
    -- 段 P_k→P_{k+1} 的右邻点是 P_{k+2}:仅当 k ≤ n-2 可渲染,
    -- 即循环条件 s._seg + 3 ≤ n(末段留给 _renderStrokeClose)
    while (s._seg or 0) + 3 <= n do
        local k = (s._seg or 0) + 1 -- 渲染段 P_k→P_{k+1}
        local p0 = pts[math.max(1, k - 1)]
        local p1, p2, p3 = pts[k], pts[k + 1], pts[k + 2]
        shapes.crSegment(pbb, p0, p1, p2, p3, s.width, gray, s.tip)
        minx = math.min(minx or p1.x, p0.x, p1.x, p2.x, p3.x)
        maxx = math.max(maxx or p1.x, p0.x, p1.x, p2.x, p3.x)
        miny = math.min(miny or p1.y, p0.y, p1.y, p2.y, p3.y)
        maxy = math.max(maxy or p1.y, p0.y, p1.y, p2.y, p3.y)
        s._seg = k
    end
    if minx then
        return minx, miny, maxx, maxy
    end
    return nil
end

-- 收尾补段:剩余末段 P_{n-1}→P_n(末侧邻位钳到末点,与 shapes.polyline 一致);
-- 只在已有增量渲染时调用。返回包围盒。
function M:_renderStrokeClose(s)
    s = s or self._stroke
    if not s or not s._tip_drawn then return nil end
    local pts = s.points
    local n = #pts
    if n < 2 then return nil end
    local gray = Blitbuffer.gray(s.gray)
    local pbb = self:_alphaBB(self.canvas_bb, s)
    local minx, miny, maxx, maxy
    while (s._seg or 0) < n - 1 do
        local k = (s._seg or 0) + 1
        local p0 = pts[math.max(1, k - 1)]
        local p1, p2 = pts[k], pts[k + 1]
        shapes.crSegment(pbb, p0, p1, p2, p2, s.width, gray, s.tip)
        minx = math.min(minx or p1.x, p0.x, p1.x, p2.x)
        maxx = math.max(maxx or p1.x, p0.x, p1.x, p2.x)
        miny = math.min(miny or p1.y, p0.y, p1.y, p2.y)
        maxy = math.max(maxy or p1.y, p0.y, p1.y, p2.y)
        s._seg = k
    end
    if minx then
        return minx, miny, maxx, maxy
    end
    return nil
end

-- 追加一个点并增量绘制新线段(直接进画布 BB,收笔前属于"进行中"笔画)
function M:_extendStroke(x, y)
    local s = self._stroke
    if not s then
        return
    end
    local pts = s.points
    local last = pts[#pts]
    if last and last.x == x and last.y == y then
        return -- 去重
    end
    -- 慢笔画会产生大量 1px 内的密集点:按笔宽比例设最小步距,步距内跳过。
    -- 步距封顶 3px:更粗的笔也不再跳过密集点,小圆弧的曲率不因抽稀被拉直
    -- (单笔内存仍有 MAX_STROKE_POINTS 收笔均匀抽稀兜底)。
    -- 圆头/粗线在步距内的墨迹完全重叠,视觉无差异,但单笔点数量级下降,
    -- 长会话的内存与橡皮/保存扫描成本都显著收敛
    local min_step = math.min(3, math.max(1, math.floor(s.width / 8)))
    if last and math.abs(last.x - x) < min_step and math.abs(last.y - y) < min_step then
        return
    end
    table.insert(pts, { x = x, y = y })
    local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
    if not rx0 then
        return
    end
    -- 节流刷新:数据实时进画布,屏幕按窗口合并区域刷新(墨水屏不逐事件刷新,防卡顿);
    -- 粗笔画用更宽的节流窗口,减少波形刷新次数
    self._stroke_region = self:_mergeRegions(self._stroke_region,
        self:_dirtyRegion(rx0, ry0, rx1, ry1, s.width + 2))
    if not self._stroke_repaint_pending then
        self._stroke_repaint_pending = true
        local interval = (s.width >= const.THICK_WIDTH)
            and const.THICK_REFRESH_INTERVAL or const.STROKE_REFRESH_INTERVAL
        -- 存闭包引用:scheduleIn 返回 nil 取不到句柄,unschedule 按闭包引用取消,
        -- 关闭/切工具时靠 _invalidateTasks 里对同一闭包 unschedule 作废任务
        local fn = function()
            self:_flushStrokeRepaint()
        end
        self._stroke_repaint_fn = fn
        UIManager:scheduleIn(interval, fn)
    end
end

-- 节流窗口到点:合并区域刷新(命名方法以便关闭时取消/统一 pcall 保护)。
-- 起笔立即刷新路径也调用这里:顺带取消已排队的节流任务,避免队列堆积。
-- 没有累积区域时**不发刷新**:setDirty(partial, nil) 在 KOReader 里等于整屏刷新
-- (还会按次数升级成 full 闪刷),墨水屏上就是一次闪屏;而"没区域"的含义正是
-- "这一笔还没有墨迹需要显示"(墨迹已在 canvas_bb 里,等下一发节流或收笔那发带
-- 区域的一起上屏),所以直接跳过是等价且更省的
function M:_flushStrokeRepaint()
    if self._stroke_repaint_fn then
        UIManager:unschedule(self._stroke_repaint_fn)
        self._stroke_repaint_fn = nil
    end
    self._stroke_repaint_pending = false
    if not self.canvas_bb then
        return -- 关闭后挂起的回调:直接丢弃,不触碰已释放状态
    end
    local reg = self._stroke_region
    self._stroke_region = nil
    if not reg then
        return
    end
    UIManager:setDirty(self, "partial", reg)
end

-- 抽稀:点数超 MAX_STROKE_POINTS 时均匀保留(保首尾)。
-- 只影响超长笔画,视觉几乎无差异;把单笔内存与后续扫描成本收敛到上限内
function M:_thinPoints(points)
    local n = #points
    if n <= const.MAX_STROKE_POINTS then
        return points
    end
    local out = {}
    local step = (n - 1) / (const.MAX_STROKE_POINTS - 1)
    for i = 1, const.MAX_STROKE_POINTS do
        local idx = math.max(1, math.min(n, math.floor(1 + (i - 1) * step + 0.5)))
        out[i] = points[idx]
    end
    out[const.MAX_STROKE_POINTS] = points[n] -- 保证尾点精确
    return out
end

function M:_finishStroke(x, y)
    local s = self._stroke
    self._stroke = nil
    if not s then
        return
    end
    local last_reg
    if x then
        local last = s.points[#s.points]
        if not last or last.x ~= x or last.y ~= y then
            table.insert(s.points, { x = x, y = y })
        end
    end
    -- 增量消费剩余点 + 收尾半段(从最后中点弯到末点,与 shapes.polyline 一致)。
    -- 显式传 s:_finishStroke 入口已把 self._stroke 置 nil,内部不能再读它
    local rx0, ry0, rx1, ry1 = self:_renderStrokeTail(s)
    local cx0, cy0, cx1, cy1 = self:_renderStrokeClose(s)
    if rx0 or cx0 then
        local minx = math.min(rx0 or cx0, cx0 or rx0)
        local miny = math.min(ry0 or cy0, cy0 or ry0)
        local maxx = math.max(rx1 or cx1, cx1 or rx1)
        local maxy = math.max(ry1 or cy1, cy1 or ry1)
        last_reg = self:_dirtyRegion(minx, miny, maxx, maxy, s.width + 2)
    end
    if #s.points > 0 then
        -- 超长笔画均匀抽稀(保首尾):限制单笔内存与后续扫描成本
        if #s.points > const.MAX_STROKE_POINTS then
            s.points = self:_thinPoints(s.points)
        end
        if self.tool == "fill" then
            -- 描边填:不提交路径元素,闭合填充后清掉路径墨迹(只留填充面)。
            -- 收笔统一走这里,消除 onPanRelease/onHold/双指 等漏触发闭合填充的分支
            self:_commitFillPath(s)
            return
        end
        table.insert(self.elements, s)
        self:_cacheBBox(s)
        self:_pushUndo({ kind = "add", el = s })
        self:_clearRedo()
        self:_log("commit stroke", s.kind, #s.points, "points, gray", s.gray, "width", s.width)
    end
    -- 收笔刷新:提交区域 = 最后一段 ∪ 节流累积区域(覆盖整笔)。
    -- 增量墨迹直接画进 canvas_bb 恒在最上,当前层之上有可见图层时必须
    -- 白刷+按层序重放恢复遮挡;重放画布已就绪,屏幕刷新保持原节流语义
    local region = self:_mergeRegions(last_reg, self._stroke_region)
    self:_commitRegionReplay(region)
    if self._stroke_repaint_pending then
        -- 节流回调挂起中:保留累积区域由回调刷屏(避免 nil 区域整屏 partial)
    else
        self._stroke_region = nil
        if region then
            UIManager:setDirty(self, "partial", region)
        end
    end
end

-- 提交后的层序修正:进行中的墨迹是直接画进 canvas_bb 的(恒压在已有墨迹之上),
-- 只有当前层**之上还有"可见且有内容"的图层**时才需要白刷+按层序重放恢复遮挡。
-- 之上没有可见内容时新墨迹本来就该在最上层,直接跳过——否则每次落笔/每个元素提交
-- 都要把区域内的元素(含整幅背景填)重放一遍,元素一多刷新就明显变慢。
-- 跳过时补一次显隐缓存作废(新版核心有乒乓缓存,增量墨迹没经 _redrawRegion)
function M:_commitRegionReplay(region)
    if not region or not self.canvas_bb then
        return
    end
    local active = self.active_layer or 2
    for li = active + 1, 3 do
        if self.layer_visible[li] and #self.layers[li] > 0 then
            self:_redrawRegion(region)
            return
        end
    end
    if self._invalidateVisCache then
        self:_invalidateVisCache()
    end
end

-- 快速轻触/轻点产生的墨点(单点笔画,可撤销;防抖不拦截主动轻点)
function M:_commitDot(x, y)
    local el = {
        kind = "freehand",
        points = { { x = x, y = y } },
        gray = self:_resolveGray(),
        alpha = self:_resolveAlpha(),
        width = self:_resolveWidth(),
        tip = self.tip,
    }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    shapes.tip(self:_alphaBB(self.canvas_bb, el), x, y, el.width, Blitbuffer.gray(el.gray), el.tip)
    self:_log("commit dot", x, y, "width", el.width)
    local region = self:_dirtyRegion(x, y, x, y, el.width + 2)
    self:_commitRegionReplay(region)
    UIManager:setDirty(self, "partial", region)
end

-- ============================ 图形工具 ============================

-- 图形工具拖动:只记录锚点与当前点,不逐帧预览刷新;
-- 手指停留 SHAPE_PREVIEW_DELAY 秒才显示一次预览(收笔仍按最后更新的点一次确认)
function M:_trackShapeAnchor(ges)
    local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
    if not x then
        return
    end
    if not self._shape_start then
        -- 锚点取按下点(画布坐标=屏幕坐标);start_pos 不在画布内时退回当前点。
        -- 灰度/粗细在起笔时取一次并固定:随机模式下预览与提交一致、粗细不随停留变化
        local sx, sy = x, y
        if ges.start_pos then
            local sxv, syv = self:_toCanvas(ges.start_pos.x, ges.start_pos.y)
            if sxv then
                sx, sy = sxv, syv
            end
        end
        self._shape_start = {
            x = sx, y = sy,
            gray = self:_resolveGray(),
            width = self:_resolveWidth(),
            alpha = self:_resolveAlpha(),
        }
    end
    self:_scheduleShapePreview(x, y)
end

-- 重新安排 SHAPE_PREVIEW_DELAY 秒预览定时器。scheduleIn 返回 nil 取不到句柄,
-- 但 unschedule 按闭包引用取消:保存调度时同一个闭包,每次 pan 先取消再重排,
-- 定时器只在手指"停留满延迟"后触发一次,不再像旧版那样堆积成批爆发(设备上
-- 曾观测到同秒 40+ 条 preview shown 刷屏)
function M:_scheduleShapePreview(x, y)
    if self._shape_preview_fn then
        UIManager:unschedule(self._shape_preview_fn)
        self._shape_preview_fn = nil
    end
    if self.preview then
        local old = self.preview
        self.preview = nil
        UIManager:setDirty(self, "partial", self:_elementRegion(old))
    end
    self._shape_pos = { x = x, y = y }
    local fn = function()
        self:_maybeShowShapePreview()
    end
    self._shape_preview_fn = fn
    UIManager:scheduleIn(const.SHAPE_PREVIEW_DELAY, fn)
end

-- 定时器到点:手指停留 ≥SHAPE_PREVIEW_DELAY,显示形状预览(锚点→当前点)
function M:_maybeShowShapePreview()
    self._shape_preview_fn = nil
    if not self.canvas_bb then
        return -- 关闭后挂起的回调:直接丢弃,不触碰已释放状态
    end
    local start = self._shape_start
    local pos = self._shape_pos
    if not (start and pos) then
        return
    end
    self.preview = self:_buildShapeElement(self.tool, start.x, start.y, pos.x, pos.y, start.gray, start.width, start.alpha)
    if self.preview and not self:_shapeIsEmpty(self.preview) then
        self._shape_preview_region = self:_elementRegion(self.preview)
        self:_log("preview shown", self.preview.kind)
        UIManager:setDirty(self, "partial", self._shape_preview_region)
    else
        self.preview = nil -- 过小形状不显示预览(落笔同样会被防抖丢弃)
    end
end

-- 取消预览定时器并清除预览元素(保留 _shape_preview_region 供收笔刷新擦除)
function M:_cancelShapePreview()
    if self._shape_preview_fn then
        UIManager:unschedule(self._shape_preview_fn)
        self._shape_preview_fn = nil
    end
    self.preview = nil
end

function M:_buildShapeElement(tool, x0, y0, x1, y1, gray, width, alpha)
    if type(x0) ~= "number" or type(y0) ~= "number" or type(x1) ~= "number" or type(y1) ~= "number" then
        self:_log("_buildShapeElement: invalid coords", tool, x0, y0, x1, y1)
        return nil
    end
    -- 灰度/粗细/透明度:起笔时(_trackShapeAnchor)取一次固定,预览与提交一致;
    -- 未传(旧调用/兜底)时现场取一次
    gray = gray or self:_resolveGray()
    width = width or self:_resolveWidth()
    alpha = alpha or self:_resolveAlpha()
    if tool == "line" then
        -- 直线(画笔长按切换的工具)带笔触形状;矩形/圆形保持圆笔触
        return { kind = "line", x0 = x0, y0 = y0, x1 = x1, y1 = y1, gray = gray, width = width, alpha = alpha, tip = self.tip }
    elseif tool == "rect" then
        return { kind = "rect", x0 = x0, y0 = y0, x1 = x1, y1 = y1,
            gray = gray, width = width, alpha = alpha, filled = self.rect_filled }
    elseif tool == "circle" then
        local r = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
        return { kind = "circle", cx = x0, cy = y0, rx = r, ry = r,
            gray = gray, width = width, alpha = alpha, filled = self.circle_filled }
    elseif tool == "eraser" then
        -- 矩形框橡皮:预览画半灰实心矩形(可见),提交时 _commitShape 改为白色擦除
        return { kind = "rect", x0 = x0, y0 = y0, x1 = x1, y1 = y1,
            gray = 0.5, width = 2, filled = true }
    end
    return nil
end

-- 收笔:用释放点重建最终元素并落盘;零尺寸(未拖动)不提交
function M:_commitShape(x, y)
    local start = self._shape_start
    self._shape_start = nil
    self:_cancelShapePreview()
    -- 曾显示的预览区域也要一并刷新(擦除预览残留)
    local prev_region = self._shape_preview_region
    self._shape_preview_region = nil
    if not start then
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    local x1, y1 = x or start.x, y or start.y
    local el = self:_buildShapeElement(self.tool, start.x, start.y, x1, y1, start.gray, start.width, start.alpha)
    if not el then
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    if self:_shapeIsEmpty(el) then
        self:_log("shape skipped (empty)", el.kind)
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    shapes.drawElement(self:_alphaBB(self.canvas_bb, el), el, Blitbuffer.gray(el.gray))
    self:_log("commit shape", el.kind, "at", start.x, start.y, "->", x1, y1)
    -- 刷新区域:元素实际范围(圆完整,不缺块) ∪ 曾显示的预览范围;
    -- 上方有可见图层时重放恢复层序(新形状不能压住高层墨迹)
    local region = self:_mergeRegions(self:_elementRegion(el), prev_region)
    self:_commitRegionReplay(region)
    UIManager:setDirty(self, "partial", region)
end

-- 落笔防抖:形状尺寸小于阈值视为误触丢弃(零尺寸同样丢弃)。
-- 阈值只按形状自身尺寸(SHAPE_MIN_SIZE),与线宽解耦——粗细上限 800 时
-- 若随笔宽放大(width*2)可达数百 px,正常尺寸的空心圆/矩形全被丢弃
function M:_shapeIsEmpty(el)
    local min_size = const.SHAPE_MIN_SIZE
    if el.kind == "line" then
        return math.sqrt((el.x1 - el.x0) ^ 2 + (el.y1 - el.y0) ^ 2) < min_size
    elseif el.kind == "rect" then
        if el.x0 == el.x1 and el.y0 == el.y1 then
            return true
        end
        return math.max(math.abs(el.x1 - el.x0), math.abs(el.y1 - el.y0)) < min_size
    elseif el.kind == "circle" then
        return (el.rx or el.r) < min_size
    end
    return false
end

-- ============================ 橡皮:删除对象 ============================

-- 删除一批对象并记录撤销(按原索引从高到低移除,索引保持有效)
-- 只白刷并重绘"被删元素范围并集"区域,画布再大也不用整幅重放
function M:_deleteElements(idxs, els)
    for j = #idxs, 1, -1 do
        table.remove(self.elements, idxs[j])
    end
    self:_pushUndo({ kind = "del", els = els, idxs = idxs })
    self:_clearRedo()
    self:_log("erase", #els, "objects")
    local region = nil
    for _, el in ipairs(els) do
        region = self:_mergeRegions(region, self:_elementRegion(el))
        if el == self._selected then
            self._selected = nil -- 被删对象是选中对象时清除选中(区域已并入重绘)
        end
    end
    if region then
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
    end
end

-- 选取点到元素"着墨点"(实际绘制像素)的距离;0 = 点在墨迹上
function M:_inkDistance(el, px, py)
    if el.kind == "freehand" or el.kind == "eraser" then
        local pts = el.points
        local d = math.huge
        for i = 2, #pts do
            local a, b = pts[i - 1], pts[i]
            local s = const.pointSegDist(px, py, a.x, a.y, b.x, b.y)
            if s < d then d = s end
        end
        if #pts == 1 then
            d = math.sqrt((px - pts[1].x) ^ 2 + (py - pts[1].y) ^ 2)
        end
        -- 笔画有厚度:墨迹表面距离 = 中心线距离 - 半径
        return math.max(0, d - (el.width or 2) / 2)
    elseif el.kind == "poly" then
        -- 闭合多边形(旋转后的矩形):各边(含首尾闭合段)的距离
        local pts = el.points
        local n = #pts
        -- 实心:内部即墨迹(偶奇规则点在多边形内,v61k 与渲染同步)
        if el.filled then
            local inside = false
            for i = 1, n do
                local a, b = pts[i], pts[(i % n) + 1]
                if (a.y <= py and b.y > py) or (b.y <= py and a.y > py) then
                    local xin = a.x + (py - a.y) * (b.x - a.x) / (b.y - a.y)
                    if px < xin then inside = not inside end
                end
            end
            if inside then
                return 0
            end
        end
        local d = math.huge
        for i = 1, n do
            local a, b = pts[i], pts[(i % n) + 1]
            local s = const.pointSegDist(px, py, a.x, a.y, b.x, b.y)
            if s < d then d = s end
        end
        return math.max(0, d - (el.width or 2) / 2)
    elseif el.kind == "line" then
        local d = const.pointSegDist(px, py, el.x0, el.y0, el.x1, el.y1)
        return math.max(0, d - (el.width or 2) / 2)
    elseif el.kind == "rect" then
        -- 实心:内部即墨迹;空心:只算四条描边
        local b = self:_elementBBox(el)
        if el.filled and px >= b.x0 and px <= b.x1 and py >= b.y0 and py <= b.y1 then
            return 0
        end
        local d = math.huge
        local xa, xb = math.min(el.x0, el.x1), math.max(el.x0, el.x1)
        local ya, yb = math.min(el.y0, el.y1), math.max(el.y0, el.y1)
        d = math.min(d, const.pointSegDist(px, py, xa, ya, xb, ya))
        d = math.min(d, const.pointSegDist(px, py, xb, ya, xb, yb))
        d = math.min(d, const.pointSegDist(px, py, xb, yb, xa, yb))
        d = math.min(d, const.pointSegDist(px, py, xa, yb, xa, ya))
        return math.max(0, d - (el.width or 2) / 2)
    elseif el.kind == "circle" then
        -- 圆/椭圆(含旋转):变换到椭圆本地系,按归一化距离近似着墨距离
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local dx, dy = px - el.cx, py - el.cy
        local rot = el.rot or 0
        if rot ~= 0 then
            local c, s = math.cos(-rot), math.sin(-rot)
            dx, dy = dx * c - dy * s, dx * s + dy * c
        end
        local dist_norm = math.sqrt((dx / rx) ^ 2 + (dy / ry) ^ 2)
        local min_r = math.min(rx, ry)
        if el.filled then
            if dist_norm <= 1 then
                return 0
            end
            return (dist_norm - 1) * min_r
        end
        -- 空心:只算椭圆周
        return math.max(0, math.abs(dist_norm - 1) * min_r - (el.width or 2) / 2)
    elseif el.kind == "text" then
        -- 文字按渲染外接框近似;旋转文字先逆变换到未旋转局部系再量距离。
        -- 逆旋转中心 = 基线左端(与 _drawTextTo/_elementBBox 同锚点:基线 = el.y + 0.8*字号)
        local e = self:_textExtent(el)
        if not e then
            return math.huge
        end
        local ax = el.x or 0
        local ay = e.baseline
        local lx, ly = px, py
        local rot = el.rot or 0
        if rot ~= 0 then
            local c, sn = math.cos(-rot), math.sin(-rot)
            lx = ax + (px - ax) * c - (py - ay) * sn
            ly = ay + (px - ax) * sn + (py - ay) * c
        end
        local b = {
            x0 = ax - 1, y0 = e.baseline - e.yt - 1,
            x1 = ax + e.w + 1, y1 = e.baseline + e.yb + 1,
        }
        local dx = math.max(b.x0 - lx, 0, lx - b.x1)
        local dy = math.max(b.y0 - ly, 0, ly - b.y1)
        return math.sqrt(dx * dx + dy * dy)
    elseif el.kind == "fill" then
        -- 填充结果按包围盒近似(不可选取,仅兜底)
        local b = self:_elementBBox(el)
        if not b then
            return math.huge
        end
        local dx = math.max(b.x0 - px, 0, px - b.x1)
        local dy = math.max(b.y0 - py, 0, py - b.y1)
        return math.sqrt(dx * dx + dy * dy)
    end
    return math.huge
end

-- 选取点击点处"最上层可见"的对象:倒序(绘制序=下层→上层,后画者在上)遍历,
-- 点击点正好落在某对象着墨上(距离 0 = 该处被它盖住/可见)立即返回该层最上的对象;
-- 都不在着墨上(点在空白间隙)时退回"着墨距离最近"的候选(容差内可点中)。
-- 填充结果(fill)也可选(移动/复制/灰度/缩放;墨迹距离按 bbox 近似)
function M:_pickElementAt(x, y, tolerance)
    tolerance = tolerance or const.PICK_TOLERANCE
    -- 当前层隐藏时其元素全部不可见,点选/点删都不应命中(v57 对抗性测试暴露)
    if not self.layer_visible[self.active_layer] then
        return nil
    end
    local best_i, best_d = nil, math.huge
    for i = #self.elements, 1, -1 do
        local el = self.elements[i]
        local b = el._bbox or self:_elementBBox(el)
        if b and x >= b.x0 - tolerance and x <= b.x1 + tolerance
            and y >= b.y0 - tolerance and y <= b.y1 + tolerance then
            local d = self:_inkDistance(el, x, y)
            if d <= 0 then
                return el, i -- 最上层可见对象(该点处盖住下层)
            end
            if d < best_d then
                best_d = d
                best_i = i
            end
        end
    end
    if best_i and best_d <= tolerance then
        return self.elements[best_i], best_i
    end
    return nil
end

-- 点按删除:删除点击点处"最上层可见"的对象(距离 0 优先,倒序取最上;
-- 点在间隙时按最近着墨);距所有墨迹都超过容差则视为点空白,不删除
function M:_eraseAt(x, y)
    local el, i = self:_pickElementAt(x, y)
    if el then
        self:_deleteElements({ i }, { el })
        return true
    end
    return false
end

-- 框选:删除与矩形相交的对象(相交判定走缓存 bbox)
function M:_eraseInRect(x0, y0, x1, y1)
    local xa, ya = math.min(x0, x1), math.min(y0, y1)
    local xb, yb = math.max(x0, x1), math.max(y0, y1)
    local idxs, els = {}, {}
    for i, el in ipairs(self.elements) do
        local b = el._bbox or self:_elementBBox(el)
        if b and b.x0 <= xb and b.x1 >= xa and b.y0 <= yb and b.y1 >= ya then
            table.insert(idxs, i)
            table.insert(els, el)
        end
    end
    if #els > 0 then
        self:_deleteElements(idxs, els)
    end
end

-- 画笔擦:拖动收集路径点(不绘制、不刷新,快)
function M:_trackErasePath(ges)
    if not self._erase_path then
        self._erase_path = { points = {} }
    end
    local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
    if x then
        local pts = self._erase_path.points
        local last = pts[#pts]
        if not last or last.x ~= x or last.y ~= y then
            table.insert(pts, { x = x, y = y })
        end
    end
end

-- 画笔擦收笔:删除与路径包围盒相交的对象
function M:_commitErasePath(x, y)
    local path = self._erase_path
    self._erase_path = nil
    if not path or #path.points == 0 then
        return
    end
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(path.points) do
        if p.x < minx then minx = p.x end
        if p.y < miny then miny = p.y end
        if p.x > maxx then maxx = p.x end
        if p.y > maxy then maxy = p.y end
    end
    local m = self.width + 4
    self:_eraseInRect(minx - m, miny - m, maxx + m, maxy + m)
end

-- 矩形框擦收笔:删除框内对象(锚点与 0.5s 灰框预览复用图形工具机制)
function M:_commitEraseRect(x, y)
    local start = self._shape_start
    self._shape_start = nil
    self:_cancelShapePreview()
    self._shape_preview_region = nil
    if not start then
        return
    end
    local x1, y1 = x or start.x, y or start.y
    self:_eraseInRect(start.x, start.y, x1, y1)
end

-- ============================ 填充工具 ============================

-- 洪泛填充:从 (sx,sy) 起,填充连通区域(边缘感知,扫描线算法)。
-- 展开到相邻像素要求:①与相邻像素局部差 ≤ FILL_EDGE_TOLERANCE(局部边缘检测——
-- 浅色描边与白背景差 >8 即成边界,与种子色无关,5%~9% 及更浅描边都能识别);
-- ②与种子像素差 ≤ FILL_TOLERANCE(整体一致兜底,防沿缓变梯度爬走)。
-- 不改画布像素,返回 span 列表 { {y, x0, x1}, ... } 供 fill 元素重放
function M:_floodFillSpans(bb, sx, sy, tol)
    local bw, bh = bb:getWidth(), bb:getHeight()
    if sx < 0 or sx >= bw or sy < 0 or sy >= bh then
        return nil
    end
    local p0 = bb:getPixel(sx, sy)
    if not p0 then
        return nil
    end
    local target = p0.a
    local edge_tol = const.FILL_EDGE_TOLERANCE
    local function pval(px, py)
        local p = bb:getPixel(px, py)
        return p and p.a or -1
    end
    local function fillable(px, py, ref)
        local a = pval(px, py)
        return a >= 0 and math.abs(a - ref) <= edge_tol and math.abs(a - target) <= tol
    end
    local spans = {}
    local seen = {} -- seen[y] = 已处理的 {x0,x1} 列表
    local function overlaps(y, x0, x1)
        local list = seen[y]
        if not list then
            return false
        end
        for _, s in ipairs(list) do
            if x1 >= s[1] and x0 <= s[2] then
                return true
            end
        end
        return false
    end
    local stack = { { sy, sx, sx } }
    while #stack > 0 do
        local seg = table.remove(stack)
        local y, x0, x1 = seg[1], seg[2], seg[3]
        local e0, e1 = x0, x1 -- 当前行向两侧扩展(与相邻像素比)
        while e0 - 1 >= 0 and fillable(e0 - 1, y, pval(e0, y)) do e0 = e0 - 1 end
        while e1 + 1 < bw and fillable(e1 + 1, y, pval(e1, y)) do e1 = e1 + 1 end
        if not overlaps(y, e0, e1) then
            if not seen[y] then seen[y] = {} end
            table.insert(seen[y], { e0, e1 })
            table.insert(spans, { y, e0, e1 })
            for _, ny in ipairs({ y - 1, y + 1 }) do -- 上下相邻行找新种子段(与正上/下方像素比)
                if ny >= 0 and ny < bh then
                    local nx = e0
                    while nx <= e1 do
                        if fillable(nx, ny, pval(nx, y)) then
                            local s0, s1 = nx, nx
                            while s0 - 1 >= e0 and fillable(s0 - 1, ny, pval(s0, ny)) do s0 = s0 - 1 end
                            while s1 + 1 <= e1 and fillable(s1 + 1, ny, pval(s1, ny)) do s1 = s1 + 1 end
                            if not overlaps(ny, s0, s1) then
                                table.insert(stack, { ny, s0, s1 })
                            end
                            nx = s1 + 1
                        else
                            nx = nx + 1
                        end
                    end
                end
            end
        end
    end
    return spans
end

-- 点填:洪泛填充点击点所在封闭区域,结果存为 fill 元素(可撤销;区域重绘按 span 重放)
function M:_fillAt(x, y)
    if not self.canvas_bb then
        return
    end
    local spans = self:_floodFillSpans(self.canvas_bb,
        math.floor(x), math.floor(y), const.FILL_TOLERANCE)
    if not spans or #spans == 0 then
        return
    end
    local el = { kind = "fill", spans = spans, gray = self:_resolveGray(), alpha = self:_resolveAlpha() }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    UIManager:setDirty(self, "partial", region)
    self:_log("fill at", x, y, #spans, "spans")
end

-- 闭合多边形内部 span(偶奇规则扫描线填充):只按路径自身几何计算,忽略画布其他墨迹。
-- 逐行求各边与扫描线交点(半开区间防顶点重复计数),排序后成对取区间。
-- 返回 span 列表 { {y, x0, x1}, ... }(自交路径如 8 字形按偶奇规则分块)
function M:_polygonFillSpans(pts)
    local spans = {}
    local n = #pts
    if n < 3 then
        return spans
    end
    local y_min, y_max = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p.y < y_min then y_min = p.y end
        if p.y > y_max then y_max = p.y end
    end
    for y = math.floor(y_min), math.ceil(y_max) do
        local xs = {}
        for i = 1, n do
            local a, b = pts[i], pts[(i % n) + 1]
            if (a.y <= y and b.y > y) or (b.y <= y and a.y > y) then
                table.insert(xs, a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
            end
        end
        table.sort(xs)
        local i = 1
        while i < #xs do
            local x0 = math.ceil(xs[i] - 0.5)
            local x1 = math.floor(xs[i + 1] + 0.5)
            if x1 >= x0 then
                table.insert(spans, { y, x0, x1 })
            end
            i = i + 2
        end
    end
    return spans
end

-- Chaikin corner cutting 平滑闭合路径(含起笔点/落笔点,循环覆盖首尾)。
-- 每轮迭代对每个顶点在其与相邻顶点的连线上取 1/4 与 3/4 两个新点,
-- 新点恒在折线上 → 天然无过冲、无尖峰、无尖角(收敛到二次均匀 B 样条,C1 平滑);
-- 迭代 rounds 轮后末点回到首点闭合。不假设首=末:先去掉与首点重合的末点,
-- 再对唯一点序列循环(闭合段由落笔趋势延续到起点,自然圆滑)。
-- 返回闭合的平滑点序列(供填充边界扫描)
function M:_smoothClosedPath(pts, rounds)
    rounds = rounds or 2
    local n = #pts
    -- 去掉与首点重合的末点(用户已闭合);未闭合(末≠首)则保留全部点,循环自动闭合
    local first = pts[1]
    local last_p = pts[n]
    if last_p and last_p.x == first.x and last_p.y == first.y then
        n = n - 1
    end
    if n < 3 then
        return pts -- 不足以构成闭合区域,直接返回
    end
    local cur = {}
    for i = 1, n do
        cur[i] = { x = pts[i].x, y = pts[i].y }
    end
    local m = n
    for r = 1, rounds do
        local nxt = {}
        for i = 1, m do
            -- 段 P1→P2 产生 3/4 点(靠近 P1)与 1/4 点(靠近 P2),标准 corner cutting
            local p1 = cur[i]
            local p2 = cur[(i % m) + 1]
            nxt[#nxt + 1] = {
                x = p1.x * 0.75 + p2.x * 0.25,
                y = p1.y * 0.75 + p2.y * 0.25,
            }
            nxt[#nxt + 1] = {
                x = p1.x * 0.25 + p2.x * 0.75,
                y = p1.y * 0.25 + p2.y * 0.75,
            }
        end
        cur = nxt
        m = #cur
    end
    -- 闭合:末点回到平滑序列的首点(Chaikin 切角后首点=首段 3/4 点,非原始起点)
    local first = cur[1]
    local last = cur[#cur]
    if last and (last.x ~= first.x or last.y ~= first.y) then
        cur[#cur + 1] = { x = first.x, y = first.y }
    end
    return cur
end

-- 描边填收笔:路径画时可见(界定区域),收笔后只留填充面、路径墨迹被清除。
-- 路径不作为元素提交;按自身几何(偶奇规则)算内部,不理会画布其他笔画;
-- 退化(点数不足/共线)时清掉路径墨迹、不留任何东西。
function M:_commitFillPath(s)
    if not s or not s.points or #s.points < 3 then
        -- 退化路径:白刷已画的路径墨迹,不留路径也不留填充
        if s then
            local region = self:_elementRegion(s)
            if region then
                self:_redrawRegion(region)
                UIManager:setDirty(self, "partial", region)
            end
        end
        return
    end
    -- 取消挂起的笔画节流(避免收笔后僵尸定时器多刷一次旧区域)
    if self._stroke_repaint_fn then
        UIManager:unschedule(self._stroke_repaint_fn)
        self._stroke_repaint_fn = nil
    end
    self._stroke_repaint_pending = false
    self._stroke_region = nil
    -- 画时路径墨迹区域(此时末点仍是原落点,覆盖全部已画墨迹)
    local path_region = self:_elementRegion(s)
    local pts = s.points
    -- 不吸附末点(保留原落笔点):闭合由 _smoothClosedPath 循环处理,
    -- 落笔趋势自然延续到起点,闭合处无"吸附直线段"造成的尖峰
    local smooth = self:_smoothClosedPath(pts)
    local spans = self:_polygonFillSpans(smooth)
    if #spans == 0 then
        -- 共线退化:清掉路径墨迹,不留填充
        if path_region then
            self:_redrawRegion(path_region)
            UIManager:setDirty(self, "partial", path_region)
        end
        return
    end
    -- src_points 保存平滑后源顶点:后续旋转/缩放只变换顶点重算 spans,
    -- 不再从量化 span 反建几何,避免逐次变换向外漂移(穿模细线)
    local el = { kind = "fill", spans = spans, src_points = smooth,
        gray = s.gray or self:_resolveGray(), alpha = s.alpha or self:_resolveAlpha() }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el }) -- 单条撤销记录(一次撤销即清空填充)
    self:_clearRedo()
    -- 白刷 路径区域∪填充区域 并重绘:fill 元素被重绘,路径非元素不重绘 → 路径墨迹消失
    local region = self:_mergeRegions(path_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    UIManager:setDirty(self, "partial", region)
    self:_log("fill closed path", #spans, "spans")
end

return M
