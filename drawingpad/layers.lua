--[[--
drawingpad.layers — 图层(3 层,每层独立)方法(DrawingCanvas 混合模块)。

v62d:模块侧显隐乒乓缓存(不改核心文件——真机核心是回滚版,不能动)。
本模块定义 _applyVisibilityToggle/_visibleMask/_invalidateVisCache(真机回滚版核心没有,
开发树新版核心有同名方法、逻辑一致;模块合并晚于核心 → 两边都被本模块版本覆盖生效)。
画布内容变动时的缓存作废由核心的 _redrawRegion/_renderAll 直接调用
(设备补丁版核心已加;开发树核心本就有),本模块只提供缓存本体。
显隐切换由此恢复 v61x 的速度(交替显隐第 2 次起零重绘,代价是多持有一整幅画布 BB,
PW3 约 1.5MB,关闭画板时释放;若设备内存吃紧,删掉本文件"乒乓缓存"一节即回到重放路径)。
--]]

local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")

local M = {}

-- 切到指定层(1..3):重绑 元素/撤销/重做 引用,清理进行中状态与选中。
function M:_switchLayer(n)
    n = ((n - 1) % 3) + 1
    if n == self.active_layer then
        return
    end
    self.active_layer = n
    self.elements = self.layers[n]
    self.undo = self.layers_undo[n]
    self.redo = self.layers_redo[n]
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
    self:_log("layer ->", n)
    self:_updateStatus()
    UIManager:setDirty(self, "full")
end

-- 长按图层:切换当前层 显示/隐藏(隐藏层不渲染、不导出 PNG)
function M:_toggleLayerVisible()
    self.layer_visible[self.active_layer] = not self.layer_visible[self.active_layer]
    self:_log("layer visible", self.active_layer, self.layer_visible[self.active_layer])
    self:_syncToolLabels() -- 角标 ▾/▴ 随显隐翻转
    self:_updateStatus()
    -- 乒乓缓存:目标状态有缓存画面则整幅交换(零重绘),否则重放一次并缓存旧状态
    self:_refreshAfterVisibilityToggle()
end

-- 图层面板(v59d):切换任意层的显隐(当前层走 _toggleLayerVisible;其他层直接翻标记)
function M:_toggleLayerVisibleOf(n)
    if self.active_layer == n then
        return self:_toggleLayerVisible()
    end
    self.layer_visible[n] = not self.layer_visible[n]
    self:_log("layer visible", n, self.layer_visible[n])
    self:_syncToolLabels()
    self:_refreshAfterVisibilityToggle()
end

-- 显隐落地刷新。乒乓缓存(v61w 起)只是"整幅交换缓冲"的加速,不是功能本体——
-- 真机上曾把带缓存的核心文件回滚成旧版(缺 _applyVisibilityToggle),而这两个调用点
-- 还在,于是长按图层整个失效(错误被 wrapHandler 吞掉,只留一行日志)。
-- 这里按能力探测:本模块已提供 _applyVisibilityToggle(见文件头),两个版本的核心都能用
function M:_refreshAfterVisibilityToggle()
    if self._applyVisibilityToggle then
        self:_applyVisibilityToggle()
    else
        self:_renderAll()
    end
end

-- ============================ 显隐乒乓缓存(模块侧,v62d) ============================

-- 可见层掩码(1=下,2=中,4=上)
function M:_visibleMask()
    local mask = 0
    for li = 1, 3 do
        if self.layer_visible[li] then
            mask = mask + 2 ^ (li - 1)
        end
    end
    return mask
end

-- 显隐乒乓缓存作废(元素内容变动/关闭画板时调用;nil 安全,旧核心随手可调)
function M:_invalidateVisCache()
    if self._vis_cache then
        if self._vis_cache.bb and self._vis_cache.bb.free then
            self._vis_cache.bb:free()
        end
        self._vis_cache = nil
    end
end

-- 图层显隐切换:目标状态有缓存画面则整幅交换缓冲(零重绘),否则重放一次、
-- 旧状态画布留作缓存——交替显隐(对比图层)第 2 次起全部命中。
-- 画布尺寸不符(理论只在换屏/重建后)或无缓存时退化为一次普通重放
function M:_applyVisibilityToggle()
    local new_mask = self:_visibleMask()
    local old_mask = self._canvas_mask or new_mask
    local cw, ch = self.canvas_w, self.canvas_h
    local cache = self._vis_cache
    if cache and cache.mask == new_mask and cache.w == cw and cache.h == ch then
        self._vis_cache.bb, self.canvas_bb = self.canvas_bb, cache.bb
        self._vis_cache.mask = old_mask
    else
        local old_canvas = self.canvas_bb
        local spare = cache and cache.w == cw and cache.h == ch and cache.bb or nil
        self._vis_cache = nil
        if not spare then
            spare = Blitbuffer.new(cw, ch, Blitbuffer.TYPE_BB8)
        end
        spare:paintRect(0, 0, cw, ch, Blitbuffer.COLOR_WHITE)
        self.canvas_bb = spare
        self:_drawAllLayers()
        self._vis_cache = { mask = old_mask, bb = old_canvas, w = cw, h = ch }
    end
    self._canvas_mask = new_mask
    UIManager:setDirty(self, "full")
end

-- ============================ 图层面板:当前层透明度 ============================

-- 图层面板"当前层透明度"(0-100%,100=不透明):滑条+预设档位。
-- showValuePicker 拖动中不触发 onchange(释放/预设/点按才应用),每次应用整幅重放
-- (层系数影响整层全部元素,走 _renderAll 而非显隐乒乓——缓存画面带旧透明度,必须作废)
function M:_pickLayerAlpha()
    local n = self.active_layer
    local cur = (self.layer_alpha and self.layer_alpha[n]) or 1
    self:_showValuePicker{
        title = "Layer opacity(100%=opaque)",
        value = math.floor(cur * 100 + 0.5),
        min = 0,
        max = 100,
        unit = "%",
        onchange = function(v)
            self.layer_alpha[n] = v / 100
            self:_renderAll()
            -- 整层灰度值变化,partial 会留残影,补一次 "ui" 全幅匀平
            UIManager:setDirty(self, "ui")
        end,
        onclose = function()
            self:_syncToolLabels() -- 面板条目文本带当前值,改完即刷
            self:_log("layer alpha", n, self.layer_alpha[n])
        end,
    }
end

return M
