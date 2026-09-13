--[[--
drawingpad.tools — 工具状态与切换方法(DrawingCanvas 混合模块)。
--]]

local M = {}

-- 切工具:清理进行中状态/选中/挂起任务,同步按钮标签与状态栏。
-- 点"文字"工具时若选择工具下选中了文字对象 → 弹属性修改菜单(内容/字体/字号),不切工具
function M:_setTool(tool)
    if tool == "text" and self._selected and self._selected.kind == "text" then
        self:_editSelectedText()
        return
    end
    self.tool = tool
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
    self:_syncToolLabels()
    self:_log("tool ->", tool)
    self:_updateStatus()
end

-- v61p 清理:旧"长按画笔切直线"(_toggleBrushLine)已无入口,v59b 起画笔/直线为独立条目

-- 长按矩形/圆形:切换实心/空心
function M:_toggleFilled(shape)
    if shape == "rect" then
        self.rect_filled = not self.rect_filled
    else
        self.circle_filled = not self.circle_filled
    end
    self:_log("filled", shape, self.rect_filled, self.circle_filled)
    self:_syncToolLabels() -- 角标 ▾/▴ 随模式翻转
    self:_updateStatus()
end

-- 长按橡皮:切换画笔删(轨迹) / 框选删(框选)
function M:_toggleEraserMode()
    self.eraser_mode = (self.eraser_mode == "rect") and "brush" or "rect"
    self:_log("eraser_mode ->", self.eraser_mode)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- 长按填充:切换 点填(点封闭区域单色填充)/ 描边填(画笔描边,闭合起点落点填内部)
function M:_toggleFillMode()
    self.fill_mode = (self.fill_mode == "path") and "tap" or "path"
    self:_log("fill_mode ->", self.fill_mode)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- 长按灰度:切换 固定/随机 模式(随机:每次落笔从 [min,max] 均分 N 级随机取)
function M:_toggleGrayRandom()
    self.gray_random = not self.gray_random
    self:_log("gray_random ->", self.gray_random)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- 长按粗细:切换 固定/随机 模式
function M:_toggleWidthRandom()
    self.width_random = not self.width_random
    self:_log("width_random ->", self.width_random)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- 从 [vmin,vmax] 均分 levels 级随机取一个值(levels=2 只出两端;vmax<=vmin 退化返回 vmin)
function M:_randomLeveled(vmin, vmax, levels)
    levels = math.max(2, math.floor(levels or 8))
    if vmax <= vmin then
        return vmin
    end
    local i = math.random(levels)
    return vmin + (vmax - vmin) * (i - 1) / (levels - 1)
end

-- 解析下次落笔灰度:固定模式返回当前值,随机模式从分级中随机取
function M:_resolveGray()
    if not self.gray_random then
        return self.gray
    end
    return self:_randomLeveled(self.gray_min, self.gray_max, self.gray_levels)
end

-- 解析下次落笔粗细:固定模式返回当前值,随机模式从分级中随机取
function M:_resolveWidth()
    if not self.width_random then
        return self.width
    end
    return self:_randomLeveled(self.width_min, self.width_max, self.width_levels)
end

-- 长按透明度:切换 固定/随机 模式(随机:每次落笔从 [min,max] 均分 N 级随机取)
function M:_toggleAlphaRandom()
    self.alpha_random = not self.alpha_random
    self:_log("alpha_random ->", self.alpha_random)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- 解析下次落笔透明度(0-1,1=不透明):固定模式返回当前值,随机模式从分级中随机取
function M:_resolveAlpha()
    if not self.alpha_random then
        return self.alpha
    end
    return self:_randomLeveled(self.alpha_min, self.alpha_max, self.alpha_levels)
end

return M
