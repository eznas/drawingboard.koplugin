--[[--
drawingpad.actions — 撤销/重做/清空/刷新/保存/关闭方法(DrawingCanvas 混合模块)。
--]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local components = require("drawingpad.components")
local const = require("drawingpad.const")
local L = require("drawingpad.i18n")
local _ = require("gettext")

local M = {}

-- v61p 清理:v59b 扁平化后 旧合并按钮家族(_doUndoRedo/_toggleUndoMode/
-- _doRefreshClear/_toggleClearMode)与 undo_mode/clear_mode 字段已无 UI 入口,全删

-- 全屏刷新(一级底栏刷新键):只发一次 full 波形清 EPD 残影,不再整幅重放元素。
-- v62d:旧版先 _renderAll 重建画布是修"旧版局部重绘越界涂写烧错画布"的——v61w 起
-- 区域重绘走隔离临时 BB、提交恒有层序重放,画布增量保持正确,重放成了纯开销
-- (多元素时明显变慢,用户实测);内容修正仍由 图层显隐/编辑操作 的重放路径承担。
-- 若将来出现"画布烧错且刷新修不了",恢复这里的 self:_renderAll() 即可
function M:_refreshCanvas()
    UIManager:setDirty(self, "full")
    self:_log("full refresh")
end

-- ============================ 撤销 / 重做 / 清空 ============================

-- 压入撤销记录;超过 UNDO_LIMIT 丢弃最旧(防内存无限增长)
function M:_pushUndo(rec)
    table.insert(self.undo, rec)
    if #self.undo > const.UNDO_LIMIT then
        table.remove(self.undo, 1)
    end
end

-- 清空当前层 redo 栈:v61p 修复——历史上 17 处 `self.redo = {}` 用新表替换栈对象,
-- 切断与 layers_redo[层号] 的绑定,切层往返后引用漂移、redo 记录丢失;必须原位清空
function M:_clearRedo()
    for i = #self.redo, 1, -1 do
        self.redo[i] = nil
    end
end

-- 撤销:操作记录栈(add=移除该元素,del=恢复被删元素到原位)
-- 只重绘受影响区域(被移元素/被恢复元素的范围并集),不再整幅重放
function M:_undo()
    local rec = table.remove(self.undo)
    if not rec then
        return
    end
    local region = nil
    if rec.kind == "add" then
        if rec.els then
            -- 组合记录(如描边填 = 填充+描边):逐个按引用移除,刷新区域取并集
            for _, el in ipairs(rec.els) do
                for i = #self.elements, 1, -1 do
                    if self.elements[i] == el then
                        table.remove(self.elements, i)
                        break
                    end
                end
                region = self:_mergeRegions(region, self:_elementRegion(el))
            end
        else
            -- 从 elements 移除该元素(按引用)
            for i = #self.elements, 1, -1 do
                if self.elements[i] == rec.el then
                    table.remove(self.elements, i)
                    break
                end
            end
            region = self:_elementRegion(rec.el)
        end
    elseif rec.kind == "del" then
        -- 恢复被删除的元素到原索引(升序插入保持位置;钳制防越界)
        for j = 1, #rec.els do
            local idx = math.min(rec.idxs[j], #self.elements + 1)
            table.insert(self.elements, idx, rec.els[j])
        end
        for _, el in ipairs(rec.els) do
            region = self:_mergeRegions(region, self:_elementRegion(el))
        end
    elseif rec.kind == "move" then
        -- 移动撤销:按反向量平移回去,重绘 撤销前∪撤销后 区域
        local old_region = self:_elementRegion(rec.el)
        self:_moveElement(rec.el, -rec.dx, -rec.dy)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    elseif rec.kind == "transform" then
        -- 变形撤销:恢复几何快照(缩放/旋转),重绘 撤销前∪撤销后 区域
        local old_region = self:_elementRegion(rec.el)
        self:_restoreGeom(rec.el, rec.orig)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    end
    table.insert(self.redo, rec)
    self:_log("undo", rec.kind)
    if self._selected then
        region = self:_mergeRegions(region, self:_elementRegion(self._selected))
        self._selected = nil -- 撤销后选中对象可能已变,清空选中(高亮随区域重绘清除)
    end
    if region then
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
    end
end

function M:_redo()
    local rec = table.remove(self.redo)
    if not rec then
        return
    end
    local region = nil
    if rec.kind == "add" then
        if rec.els then
            -- 组合记录按列表顺序追加(填充→描边),保持 填充在下、描边在上 的层序
            for _, el in ipairs(rec.els) do
                table.insert(self.elements, el)
                region = self:_mergeRegions(region, self:_elementRegion(el))
            end
        else
            -- 追加回末尾(add 总是追加提交)
            table.insert(self.elements, rec.el)
            region = self:_elementRegion(rec.el)
        end
    elseif rec.kind == "del" then
        -- 再次删除(按引用)
        for _, el in ipairs(rec.els) do
            for i = #self.elements, 1, -1 do
                if self.elements[i] == el then
                    table.remove(self.elements, i)
                    break
                end
            end
        end
        for _, el in ipairs(rec.els) do
            region = self:_mergeRegions(region, self:_elementRegion(el))
        end
    elseif rec.kind == "move" then
        -- 移动重做:按正向向量再平移一次,重绘 重做前∪重做后 区域
        local old_region = self:_elementRegion(rec.el)
        self:_moveElement(rec.el, rec.dx, rec.dy)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    elseif rec.kind == "transform" then
        -- 变形重做:恢复最终几何快照
        local old_region = self:_elementRegion(rec.el)
        self:_restoreGeom(rec.el, rec.final)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    end
    table.insert(self.undo, rec)
    self:_log("redo", rec.kind)
    if self._selected then
        region = self:_mergeRegions(region, self:_elementRegion(self._selected))
        self._selected = nil -- 重做后选中对象可能已变,清空选中(高亮随区域重绘清除)
    end
    if region then
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
    end
end

function M:_clearAll()
    if #self.elements == 0 then
        return
    end
    UIManager:show(ConfirmBox:new{
        text = L.x(_("Clear this layer? Cannot be undone.")),
        ok_text = L.x(_("Clear")),
        cancel_text = L.x(_("Cancel")),
        ok_callback = function()
            -- 只清当前层:原位重置该层的 元素/撤销/重做,保持引用关系
            self.layers[self.active_layer] = {}
            self.elements = self.layers[self.active_layer]
            self.layers_undo[self.active_layer] = {}
            self.undo = self.layers_undo[self.active_layer]
            self.layers_redo[self.active_layer] = {}
            self.redo = self.layers_redo[self.active_layer]
            self:_invalidateTasks()
            self._stroke = nil
            self._stroke_pending = nil
            self._shape_start = nil
            self._erase_path = nil
            self:_cancelShapePreview()
            self._shape_preview_region = nil
            self._shape_pos = nil
            self._selected = nil
            self._select_drag = nil
            self._transform = nil
            self:_renderAll()
            self:_log("clear layer", self.active_layer)
        end,
    })
end

-- ============================ 保存 ============================

-- 保存:弹对话框(文件名输入 + 文件夹选择),确认后延迟执行裁剪+编码。
-- 空画板直接提示,不进对话框
function M:_save()
    if #self.elements == 0 then
        components.showToast(_("Canvas is empty, nothing to save."), 2)
        return
    end
    local dlg
    local function folderLabel()
        local f = self.save_folder
        if f == "" then
            return L.t("文件夹: 根目录", "Folder: root")
        end
        if #f > 26 then
            f = "…" .. f:sub(-24) -- 长绝对路径截断显示(按钮空间有限)
        end
        return L.t("文件夹: ", "Folder: ") .. f
    end
    local function updateFolderLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["folder_btn"]
        if btn and btn.setText then
            btn:setText(folderLabel(), btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    dlg = InputDialog:new{
        title = L.x("保存 PNG"),
        input = os.date("drawing_%Y%m%d_%H%M%S"),
        input_hint = L.x("Filename(auto .png)"),
        buttons = {
            {
                { id = "folder_btn", text = folderLabel(),
                  callback = function() self:_pickSaveFolder(updateFolderLabel, function(name)
                      dlg:setInputText(name) -- 点已有 PNG:预填文件名(自动补 .png)
                  end) end },
            },
            {
                { text = L.x(_("Cancel")), id = "close",
                  callback = function() UIManager:close(dlg) end },
                { text = L.x(_("Save")), is_enter_default = true,
                  callback = function()
                      local name = dlg:getInputText()
                      UIManager:close(dlg)
                      self:_doSaveFlow(name)
                  end },
            },
        },
    }
    -- 对话框按钮即时响应(去掉 flash_ui 阻塞,公共组件)
    components.instantButtons(dlg.button_table)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- 按对话框输入执行保存流程:组装路径 → 重名加序号 → "保存中"提示 → 延迟 _doSave。
-- v57:文件名拦斜杠(防把 "/" 当目录分隔写进意外路径);失败自动重试 1 次(SD 卡偶发繁忙)
function M:_doSaveFlow(filename)
    if not filename or filename == "" then
        filename = os.date("drawing_%Y%m%d_%H%M%S")
    end
    -- 文件名不能含路径分隔符:用户输入 "a/b" 会把 b.png 写进不存在的 a/ 目录
    if filename:find("[/\\]") then
        components.showToast("Filename cannot contain / or \\", 3)
        return
    end
    filename = filename .. ".png" -- 自动补扩展名
    local lfs = require("libs/libkoreader-lfs")
    local base = DataStorage:getDataDir() .. "/drawingboard"
    if lfs.attributes(base, "mode") ~= "directory" then
        pcall(lfs.mkdir, base)
    end
    local dir = base
    if self.save_folder ~= "" then
        dir = self.save_folder -- 绝对路径(文件夹浏览器任选;缺失则创建)
        if lfs.attributes(dir, "mode") ~= "directory" then
            pcall(lfs.mkdir, dir)
        end
    end
    local path = self:_nextSavePath(dir, lfs, filename)
    -- 延迟到下一帧执行,让保存对话框先关闭;阻塞的裁剪/编码整体包 pcall。
    -- 失败重试 1 次(0.5s 后):真机 SD 卡偶发繁忙导致首次写盘失败,作品不能因此丢失
    UIManager:scheduleIn(0.01, function()
        local ok, saved_path = pcall(self._doSave, self, path)
        if ok and saved_path then
            self:_log("saved", saved_path)
            components.showToast(L.x("Saved:") .. "\n" .. saved_path, 4)
            return
        end
        self:_log("save failed, retrying", path, ok and "" or tostring(saved_path))
        UIManager:scheduleIn(0.5, function()
            -- 重试换新路径(首试可能留下 0 字节坏文件)
            local retry_path = self:_nextSavePath(dir, lfs, filename)
            local ok2, saved2 = pcall(self._doSave, self, retry_path)
            if ok2 and saved2 then
                self:_log("saved (retry)", saved2)
                components.showToast(L.x("Saved:") .. "\n" .. saved2, 4)
            else
                self:_log("save retry failed", retry_path, ok2 and "" or tostring(saved2))
                components.showToast(L.x("Save failed, check folder permission:") .. "\n" .. dir)
            end
        end)
    end)
end

-- 生成不冲突的保存路径:重名自动加序号(避免互相覆盖)。
-- filename 缺省为时间戳文件名;测试可注入固定文件名
function M:_nextSavePath(dir, lfs, filename)
    filename = filename or (os.date("drawing_%Y%m%d_%H%M%S") .. ".png")
    if not filename:find("%.png$") then
        filename = filename .. ".png"
    end
    local path = dir .. "/" .. filename
    local n = 1
    while lfs.attributes(path, "mode") == "file" do
        n = n + 1
        local stem = filename:gsub("%.png$", "")
        path = dir .. "/" .. stem .. "_" .. n .. ".png"
    end
    return path
end

-- 实际编码写入(在延迟任务里执行;同步阻塞但提示已上屏)。
-- 画布恒定全屏(坐标=屏幕坐标),直接保存完整画布 = 设备屏幕分辨率完全一致(不裁剪白边)。
-- 返回保存路径(成功)或 nil(失败);写盘带 pcall,失败不崩溃。
-- v57:写盘后校验 PNG magic——writePNG 内部吞掉 lodepng 错误,仅凭"文件存在"判断
-- 会把 0 字节/半截文件当成功,真机 SD 卡繁忙时尤甚
function M:_doSave(path)
    if not self.canvas_bb then
        return nil
    end
    local lfs = require("libs/libkoreader-lfs")
    local ok = pcall(function()
        self.canvas_bb:writePNG(path)
    end)
    -- writePNG 内部吞掉 lodepng 错误,以文件是否真实生成判断成败
    local size = ok and lfs.attributes(path, "size")
    if not size then
        return nil
    end
    -- PNG magic 头 8 字节:137 80 78 71 13 10 26 10;损坏文件(0 字节/半截)在此拦截
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local magic = f:read(8)
    f:close()
    if magic ~= string.char(137, 80, 78, 71, 13, 10, 26, 10) then
        self:_log("PNG magic mismatch", path, size, "bytes")
        pcall(os.remove, path) -- 删坏文件,重试路径不会被 _nextSavePath 误判为"已占用"
        return nil
    end
    self:_log("saved", path, size, "bytes",
        string.format("(%dx%d = screen)", self.canvas_w, self.canvas_h))
    return path
end

-- ============================ 工程文件(可再编辑)保存/打开 ============================
-- v62d:元素全是纯数据表,序列化成 Lua chunk("return {...}")即工程文件(.drawing):
-- 3 层元素 + 显隐/透明度/当前层。重新打开恢复对象,可继续 移动/变形/改属性/撤销。

-- 递归序列化(只处理 number/boolean/string/table;下划线开头的私有字段如 _bbox 跳过,
-- 加载后由 _cacheBBox 重算)
local function serializeValue(v, out)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = string.format("%.4f", v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "table" then
        out[#out + 1] = "{"
        for k, val in pairs(v) do
            if type(k) == "number" then
                serializeValue(val, out)
                out[#out + 1] = ","
            elseif type(k) == "string" and type(val) ~= "function"
                and k:sub(1, 1) ~= "_" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") then
                out[#out + 1] = k .. "="
                serializeValue(val, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    end
end

-- 序列化并写入 .drawing 文件(同步小文本写盘,pcall 防权限/SD 忙)
function M:_doSaveProject(path)
    local data = {
        version = 1,
        active_layer = self.active_layer,
        layer_visible = self.layer_visible,
        layer_alpha = self.layer_alpha,
        layers = self.layers,
    }
    local out = { "return " }
    serializeValue(data, out)
    out[#out + 1] = "\n"
    local ok, err = pcall(function()
        local f = io.open(path, "w")
        if not f then
            error("cannot open " .. path)
        end
        f:write(table.concat(out))
        f:close()
    end)
    if not ok then
        self:_log("save project failed", path, tostring(err))
    end
    return ok
end

-- 保存工程:对话框(文件名 + 文件夹),确认后写入 .drawing
function M:_saveProject()
    local has_content = false
    for _, els in ipairs(self.layers) do
        if #els > 0 then
            has_content = true
            break
        end
    end
    if not has_content then
        components.showToast(_("Canvas is empty, nothing to save."), 2)
        return
    end
    local dlg
    local function folderLabel()
        local f = self.save_folder
        if f == "" then
            return L.t("文件夹: 根目录", "Folder: root")
        end
        if #f > 26 then
            f = "…" .. f:sub(-24)
        end
        return L.t("文件夹: ", "Folder: ") .. f
    end
    local function updateFolderLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["folder_btn"]
        if btn and btn.setText then
            btn:setText(folderLabel(), btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    dlg = InputDialog:new{
        title = L.x("保存工程(可再编辑)"),
        input = os.date("drawing_%Y%m%d_%H%M%S"),
        input_hint = L.x("文件名(自动补 .drawing)"),
        buttons = {
            {
                { id = "folder_btn", text = folderLabel(),
                  callback = function() self:_pickSaveFolder(updateFolderLabel) end },
            },
            {
                { text = L.x(_("Cancel")), id = "close",
                  callback = function() UIManager:close(dlg) end },
                { text = L.x(_("Save")), is_enter_default = true,
                  callback = function()
                      local name = dlg:getInputText()
                      UIManager:close(dlg)
                      self:_doSaveProjectFlow(name)
                  end },
            },
        },
    }
    components.instantButtons(dlg.button_table)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function M:_doSaveProjectFlow(filename)
    if not filename or filename == "" then
        filename = os.date("drawing_%Y%m%d_%H%M%S")
    end
    if filename:find("[/\\]") then
        components.showToast("Filename cannot contain / or \\", 3)
        return
    end
    filename = filename .. ".drawing"
    local lfs = require("libs/libkoreader-lfs")
    local base = DataStorage:getDataDir() .. "/drawingboard"
    if lfs.attributes(base, "mode") ~= "directory" then
        pcall(lfs.mkdir, base)
    end
    local dir = (self.save_folder ~= "") and self.save_folder or base
    if lfs.attributes(dir, "mode") ~= "directory" then
        pcall(lfs.mkdir, dir)
    end
    -- 重名自动加序号(与 PNG 保存同语义;_nextSavePath 硬编码 .png,这里独立小循环)
    local stem = filename:gsub("%.drawing$", "")
    local path = dir .. "/" .. filename
    local n = 1
    while lfs.attributes(path, "mode") == "file" do
        n = n + 1
        path = dir .. "/" .. stem .. "_" .. n .. ".drawing"
    end
    if self:_doSaveProject(path) then
        components.showToast(L.x("Saved:") .. "\n" .. path, 4)
        self:_log("project saved", path)
    else
        components.showToast(L.x("Save failed, check folder permission:") .. "\n" .. dir, 4)
    end
end

-- 打开工程:浏览器列 .drawing 文件(复用文件夹浏览器),选中即载入
function M:_openProject()
    self:_pickSaveFolder(nil, function(name)
        local dir = (self.save_folder ~= "") and self.save_folder
            or (DataStorage:getDataDir() .. "/drawingboard")
        self:_loadProject(dir .. "/" .. name .. ".drawing")
    end, "%.drawing$", L.x("打开工程: "))
end

-- 载入 .drawing:原位清空三层 元素/撤销/重做 再插入(保持与 layers_* 的引用绑定,
-- v61p 教训:换新表会切断绑定),恢复 显隐/透明度/当前层,整幅重绘
function M:_loadProject(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then
        components.showToast(L.x("File not found:") .. "\n" .. path, 3)
        return
    end
    local chunk_ok, chunk = pcall(loadfile, path)
    if not chunk_ok or type(chunk) ~= "function" then
        components.showToast(L.x("Corrupt project file:") .. "\n" .. path, 3)
        self:_log("load project: loadfile failed", path, tostring(chunk))
        return
    end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.layers) ~= "table" then
        components.showToast(L.x("Corrupt project file:") .. "\n" .. path, 3)
        self:_log("load project: bad data", path)
        return
    end
    for li = 1, 3 do
        local els = self.layers[li]
        for i = #els, 1, -1 do
            els[i] = nil
        end
        local und = self.layers_undo[li]
        for i = #und, 1, -1 do
            und[i] = nil
        end
        local red = self.layers_redo[li]
        for i = #red, 1, -1 do
            red[i] = nil
        end
        for _, el in ipairs(data.layers[li] or {}) do
            if type(el) == "table" and type(el.kind) == "string" then
                el._bbox = nil -- 私有字段不序列化,载入后重算
                table.insert(els, el)
                self:_cacheBBox(el)
            end
        end
    end
    local function copy3(src, default)
        local out = { true, true, true }
        if type(src) == "table" then
            for i = 1, 3 do
                out[i] = (src[i] == nil) and default or src[i]
            end
        end
        return out
    end
    self.layer_visible = copy3(data.layer_visible, true)
    self.layer_alpha = copy3(data.layer_alpha, 1.0)
    local n = math.max(1, math.min(3, math.floor(tonumber(data.active_layer) or 2)))
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
    self._canvas_mask = self:_visibleMask()
    self:_renderAll()
    UIManager:setDirty(self, "full")
    components.showToast(L.x("Opened:") .. "\n" .. path, 3)
    self:_log("project loaded", path)
end

-- ============================ 设置持久化 ============================
-- 工具状态设置(灰度/粗细/笔触/模式等)退出前自动写入插件目录 drawingpad_settings.lua,
-- 下次打开自动读取恢复。无插件目录(测试/直接构造)时跳过,静默。

function M:_loadSettings()
    if not self.plugin_path then
        return
    end
    local ok, s = pcall(function()
        local luasettings = require("luasettings")
        return luasettings:open(self.plugin_path .. "/drawingpad_settings.lua")
    end)
    if not ok or not s then
        self:_log("settings load failed")
        return
    end
    self._settings = s
    for _, k in ipairs(const.SETTING_KEYS) do
        local v = s:readSetting(k)
        if v ~= nil then
            self[k] = v
        end
    end
    -- 文字内容(上次插入内容)单独存取:_last_text 字段带下划线,不进 SETTING_KEYS 通用循环。
    -- v57:补全 _last_font/_last_font_size,让"上次文字用的字体"跨重启保留(v52 只存了文字内容,
    -- 插入模式退到 self.font 工具栏字体而非上次文字字体——重启后用户体感字体变化)。
    local function readUnderscore(key)
        local v = s:readSetting(key)
        if v ~= nil then
            self["_" .. key] = v
        end
    end
    readUnderscore("last_text")
    readUnderscore("last_font")
    readUnderscore("last_font_size")
    self:_log("settings loaded")
end

function M:_saveSettings()
    if not self._settings then
        return
    end
    for _, k in ipairs(const.SETTING_KEYS) do
        self._settings:saveSetting(k, self[k])
    end
    -- v57:三个下划线字段统一处理(_last_text/_last_font/_last_font_size)
    local function saveUnderscore(key, value)
        if value ~= nil then
            self._settings:saveSetting(key, value)
        end
    end
    saveUnderscore("last_text", self._last_text)
    saveUnderscore("last_font", self._last_font)
    saveUnderscore("last_font_size", self._last_font_size)
    local ok = pcall(function() self._settings:flush() end)
    self:_log("settings saved", ok)
end

-- ============================ 关闭 ============================

function M:_onClose()
    self:_saveSettings() -- 退出前自动保存工具设置到插件目录
    local function doClose()
        -- 显式 full 刷新:关闭全屏画板后确保下层页面完整重绘(plain close 只靠
        -- 兜底 partial 刷新,墨水屏上不足以清掉上一帧,页面会显得没刷新)
        UIManager:close(self, "full")
        self:_log("closed")
        if self.on_close then
            self.on_close()
        end
    end
    -- v61q:任意图层有内容都提示——self.elements 只指向当前层,
    -- 只查它会漏掉"其他层画过、当前层空白"的未保存内容
    local has_content = false
    for _, els in ipairs(self.layers) do
        if #els > 0 then
            has_content = true
            break
        end
    end
    if has_content then
        UIManager:show(ConfirmBox:new{
            text = L.x("Unsaved content, close anyway?"),
            ok_text = L.x(_("Close")),
            cancel_text = L.x(_("Cancel")),
            ok_callback = doClose,
        })
    else
        doClose()
    end
end

-- 实体键 Back 触发 "Close" 事件 → 走同一套关闭确认
function M:onClose()
    self:_onClose()
    return true
end

-- 关闭时释放画布 BlitBuffer(用 pcall 保护,防止关闭流程中崩溃)
function M:onCloseWidget()
    local ok, err = pcall(function()
        -- 关闭仍打开的分类面板(退出按钮/物理 Back 等 close 路径都经这里,
        -- 否则面板残留在窗口栈里,画板关了菜单还挂在屏幕上)
        if self._category_popup then
            -- 先清 _open_cat,面板自己的 onCloseWidget 就不会再回调 _refreshToolbar
            self._open_cat = nil
            UIManager:close(self._category_popup, "full")
            self._category_popup = nil
        end
        -- 取消所有挂起的定时任务,防止关闭后回调触碰已释放状态
        self:_invalidateTasks()
        -- 还原手势检测的 PAN_THRESHOLD(画板期间调低过;见 gestures._applyGestureTuning)
        self:_restoreGestureTuning()
        self:_cancelShapePreview()
        self._shape_preview_region = nil
        self._shape_pos = nil
        if self.canvas_bb and self.canvas_bb.free then
            self.canvas_bb:free()
            self.canvas_bb = nil
        end
        -- 释放显隐切换的乒乓缓存画面(能力探测:真机曾回滚成没有缓存的旧核心,
        -- 裸调用会在这里每次关闭都记一条 error,而它已是收尾最后一步、清理早已做完)
        if self._invalidateVisCache then
            self:_invalidateVisCache()
        end
    end)
    if not ok then
        logger.info("drawingpad: onCloseWidget error:", tostring(err))
    end
end

return M
