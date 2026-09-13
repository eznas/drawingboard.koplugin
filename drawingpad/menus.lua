--[[--
drawingpad.menus — 工具栏/状态栏/居中弹窗/文字插入/调色板/保存文件夹选择(DrawingCanvas 混合模块)。
--]]

-- 自定位:把本文件所在目录加入 package.path,使 require("shapes") 与目录无关
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- 同目录短名(shapes/const)与父目录 drawingpad.* 前缀皆可解析,与 drawingpad 所在位置无关
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")
local components = require("drawingpad.components")

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local RenderText = require("ui/rendertext")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")
local T = require("ffi/util").template
local const = require("drawingpad.const")

local M = {}

-- ============================ 工具栏 / 分类菜单 ============================

-- v59b 一级底栏图标化(参考阅读界面 TouchMenu 底栏):7 个入口用 Button{icon},
-- 等宽 7 格;激活态 = 顶部横线在当前打开面板的入口下方断开(TouchMenu 同款)。
-- 图标名见 const.TOOLBAR_ICONS(工具/属性/功能/刷新/保存/隐藏/关闭);
-- self._open_cat 记录当前打开的分类面板(nil=无,横线完整)。
-- 二级面板条目扁平化:无长按,原长按次要功能全部为独立条目(见 TOGGLE_BUTTONS);
-- 底色规则:工具类激活条目(含 矩实/复制/曲填/框擦 变体)浅灰,其余一律白底。
function M:_buildToolbar()
    local Screen_w = Screen:getWidth()
    local n = #const.TOOLBAR_ICONS
    local cell_w = math.floor(Screen_w / n)
    local icon_px = Screen:scaleBySize(const.TOOLBAR_ICON_PX)
    local row_h = icon_px + 2 * Size.padding.default
    -- 插件自带图标(资源文件随插件放在 <插件目录>/drawingpad/icons/)装入两处:
    -- ①用户 icons 目录(新版 IconWidget 优先查);②官方 resources/icons/mdlight
    -- (老版 IconWidget 没有用户目录查找逻辑,mdlight 是唯一保证被搜的目录,
    --  相对路径基于 koreader 进程 CWD)。内容与已装副本不一致时覆写。
    -- v61n:必须在本函数按钮构造之前执行——IconWidget 构造期查不到新图标会把
    -- ICON_NOT_FOUND 缓存进 ICONS_PATH(进程内永久),装晚了真机显示感叹号
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        -- 本模块 = <koplugin>/drawingpad/menus.lua → 图标资源在同级 icons/
        local src_dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") .. "/icons"
        local targets = {
            DataStorage:getDataDir() .. "/icons",
            "resources/icons/mdlight",
        }
        if lfs.attributes(src_dir, "mode") ~= "directory" then
            return
        end
        for name in lfs.dir(src_dir) do
            if name:match("%.svg$") then
                local f = io.open(src_dir .. "/" .. name, "r")
                local content = f and f:read("*a")
                if f then
                    f:close()
                end
                if content then
                    for _, icons_dir in ipairs(targets) do
                        local installed = io.open(icons_dir .. "/" .. name, "r")
                        local existing = installed and installed:read("*a")
                        if installed then
                            installed:close()
                        end
                        if existing ~= content then
                            if lfs.attributes(icons_dir, "mode") ~= "directory" then
                                lfs.mkdir(icons_dir)
                            end
                            local w = io.open(icons_dir .. "/" .. name, "w")
                            if w then
                                w:write(content)
                                w:close()
                            end
                        end
                    end
                end
            end
        end
    end)
    -- 一行图标按钮(等宽 6 格居中);v61k:取消图标背景反馈(分类高亮灰底/刷新闪烁
    -- 均移除),激活指示只保留顶部横线断口
    local cells = {}
    for i, d in ipairs(const.TOOLBAR_ICONS) do
        local btn = Button:new{
            id = d.id,
            icon = d.icon,
            icon_rotation_angle = d.icon_rotation_angle or 0,
            icon_width = icon_px,
            icon_height = icon_px,
            bordersize = 0,
            callback = function()
                if d.id == "cat_tool" then
                    self:_showCategoryMenu("tool")
                elseif d.id == "cat_prop" then
                    self:_showCategoryMenu("prop")
                elseif d.id == "cat_func" then
                    self:_showCategoryMenu("func")
                elseif d.id == "cat_layer" then
                    self:_showCategoryMenu("layer")
                elseif d.id == "refresh_btn" then
                    self:_refreshCanvas()
                elseif d.id == "hide_btn" then
                    self:_toggleMinimize()
                end
            end,
        }
        cells[i] = self:_toolbarCell(btn, cell_w, row_h)
    end
    -- 顶部横线:当前打开面板的入口下方留断口(TouchMenu 同款激活指示)
    local line_h = math.max(1, Screen:scaleBySize(1))
    local function line(w)
        return LineWidget:new{
            dimen = Geom:new{ w = w, h = line_h },
            background = Blitbuffer.COLOR_BLACK,
            style = "solid",
        }
    end
    local segs = {}
    local active_i
    local CAT_BY_ID = { cat_tool = "tool", cat_prop = "prop", cat_layer = "layer", cat_func = "func" }
    for i, d in ipairs(const.TOOLBAR_ICONS) do
        if CAT_BY_ID[d.id] and CAT_BY_ID[d.id] == self._open_cat then
            active_i = i
        end
    end
    if active_i then
        local gap_w = icon_px + Screen:scaleBySize(8)
        local gc = (active_i - 1) * cell_w + math.floor(cell_w / 2)
        local gl = math.max(0, gc - math.floor(gap_w / 2))
        local gr = math.min(Screen_w, gc + math.floor(gap_w / 2))
        if gl > 0 then
            segs[#segs + 1] = line(gl)
        end
        segs[#segs + 1] = HorizontalSpan:new{ width = gr - gl }
        if gr < Screen_w then
            segs[#segs + 1] = line(Screen_w - gr)
        end
    else
        segs[#segs + 1] = line(Screen_w)
    end
    self.toolbar = VerticalGroup:new{
        HorizontalGroup:new{ unpack(segs) },
        HorizontalGroup:new{ unpack(cells) },
    }
    local ok, size = pcall(function() return self.toolbar:getSize() end)
    self.toolbar_h = (ok and size and size.h) or Screen:scaleBySize(52)
    self.status_h = Screen:scaleBySize(28)
end

-- 底栏单格:图标按钮居中于等宽格(CenterContainer 固定尺寸格)
function M:_toolbarCell(btn, cell_w, row_h)
    local CenterContainer = require("ui/widget/container/centercontainer")
    return CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = row_h },
        btn,
    }
end

-- 最小化/恢复(覆盖核心同名方法,合并顺序在本文件生效):
-- 核心 _setMinimized 结尾发的是整屏 `setDirty(self, "full")` —— 墨水屏上就是一次
-- 可见闪屏,而真正变的像素只有底部那一条(工具栏+状态栏:最小化时画布重新露出来,
-- 恢复时工具栏重新画上;浮动"菜单"恢复键也在这条里)。这里只吸收核心那发整屏刷
-- (画布其他刷新照旧放行,如取消选中发的区域刷),改用底部一条的 "ui" 区域刷。
function M:_toggleMinimize()
    local want = not self._minimized
    if self._minimized == want then
        return
    end
    local real_setDirty = UIManager.setDirty
    UIManager.setDirty = function(uim, widget, mode, region, dither)
        if widget == self and mode == "full" then
            return
        end
        return real_setDirty(uim, widget, mode, region, dither)
    end
    local ok, err = pcall(self._setMinimized, self, want)
    UIManager.setDirty = real_setDirty
    if not ok then
        self:_log("_toggleMinimize error:", tostring(err))
    end
    local h = self.toolbar_h + self.status_h
    UIManager:setDirty(self, function()
        return "ui", Geom:new{
            x = 0, y = Screen:getHeight() - h,
            w = Screen:getWidth(), h = h,
        }
    end)
end

-- 分类面板开/关后重建工具栏(断线位置变化)+ 底部区域 "ui" 刷新
function M:_refreshToolbar()
    if self._minimized then
        return
    end
    local old_h = self.toolbar_h
    self:_buildToolbar()
    if self[1] ~= self.restore_btn then
        self[1] = self.toolbar
    end
    local h = math.max(old_h, self.toolbar_h)
    UIManager:setDirty(self, function()
        return "ui", Geom:new{
            x = 0, y = Screen:getHeight() - h - self.status_h,
            w = Screen:getWidth(), h = h + self.status_h,
        }
    end)
end

-- 分类面板条目表(v59b 扁平化:取消长按,原长按次要功能全部拆成独立条目)。
-- 每项:id/cat/label(+可选 text_fn 动态文字)/active_fn(工具类浅灰底唯一来源)/on_tap。
-- 工具类变体条目(矩实/复制/曲填/框擦)直接把状态设到位(非切换),激活判定=工具+模式;
-- close_on_tap 缺省 = 非功能类点选后关面板(功能类保持,撤销/重做/清空可连点)。
local function toolSet(tool, fields)
    return function(s)
        s:_setTool(tool)
        if fields then
            for k, v in pairs(fields) do
                s[k] = v
            end
            s:_syncToolLabels()
            s:_updateStatus()
        end
    end
end

local TOGGLE_BUTTONS = {
    -- 工具类:变体合并进主条目(名称带复选框;已激活再次点选 = 切换勾选)
    { id = "brush_btn",  cat = "tool", label = "画笔",
      active_fn = function(s) return s.tool == "brush" end,
      on_tap = toolSet("brush") },
    { id = "line_btn",   cat = "tool", label = "直线",
      active_fn = function(s) return s.tool == "line" end,
      on_tap = toolSet("line") },
    { id = "rect_btn",   cat = "tool",
      -- v59e:短按=切矩形工具,长按=切换 ☑填充
      text_fn = function(s)
          return "矩形(" .. (s.rect_filled and "☑" or "☐") .. "填充)"
      end,
      active_fn = function(s) return s.tool == "rect" end,
      on_tap = toolSet("rect"),
      on_hold = function(s) s:_setTool("rect"); s:_toggleFilled("rect") end },
    { id = "circle_btn", cat = "tool",
      text_fn = function(s)
          return "圆形(" .. (s.circle_filled and "☑" or "☐") .. "填充)"
      end,
      active_fn = function(s) return s.tool == "circle" end,
      on_tap = toolSet("circle"),
      on_hold = function(s) s:_setTool("circle"); s:_toggleFilled("circle") end },
    { id = "text_btn",   cat = "tool", label = "文字",
      active_fn = function(s) return s.tool == "text" end,
      on_tap = toolSet("text") },
    { id = "select_btn", cat = "tool",
      -- v59g:选择+复制合并(☑复制);短按=切选择工具,长按=切 ☑复制
      text_fn = function(s)
          return "选择(" .. (s.select_mode == "copy" and "☑" or "☐") .. "复制)"
      end,
      active_fn = function(s) return s.tool == "select" end,
      on_tap = toolSet("select"),
      on_hold = function(s) s:_setTool("select"); s:_toggleSelectMode() end },
    { id = "fill_btn",   cat = "tool",
      -- v59g:点填充+路径填充合并(☑路径);短按=切填充工具(点填),长按=切 ☑路径(描边填)
      text_fn = function(s)
          return "填充(" .. (s.fill_mode == "path" and "☑" or "☐") .. "路径)"
      end,
      active_fn = function(s) return s.tool == "fill" end,
      on_tap = toolSet("fill"),
      on_hold = function(s) s:_setTool("fill"); s:_toggleFillMode() end },
    { id = "eraser_btn", cat = "tool",
      -- v59f:重命名 擦除(☑框选);短按=切橡皮工具,长按=切换 画笔删/框选删
      text_fn = function(s)
          return "擦除(" .. (s.eraser_mode == "rect" and "☑框选" or "☐框选") .. ")"
      end,
      active_fn = function(s) return s.tool == "eraser" end,
      on_tap = toolSet("eraser"),
      on_hold = function(s) s:_setTool("eraser"); s:_toggleEraserMode() end },
    -- 属性设置类(随机勾选为状态显示,切换在设置弹窗内的"随机"行)
    { id = "gray_btn",  cat = "prop",
      -- v59e:短按=弹灰度设置,长按=切换 ☑随机
      text_fn = function(s)
          return "灰度(" .. (s.gray_random and "☑" or "☐") .. "随机)"
      end,
      on_tap = function(s)
          -- 有选中对象时保持选中走元素级灰度(_pickGray 内部分派);
          -- v61o:无选中直接弹全局设置,不再切画笔——属性设置不该改变当前工具
          s:_pickGray()
      end,
      on_hold = function(s) s:_toggleGrayRandom() end },
    { id = "width_btn", cat = "prop",
      text_fn = function(s)
          return "粗细(" .. (s.width_random and "☑" or "☐") .. "随机)"
      end,
      on_tap = function(s)
          -- 同灰度:选中对象时保持选中(文字/填充提示无线宽,其余对象元素级调节);
          -- v61o:不再切画笔,保持当前工具
          s:_pickWidth()
      end,
      on_hold = function(s) s:_toggleWidthRandom() end },
    { id = "tip_btn",   cat = "prop", label = "笔触",
      on_tap = function(s) s:_showTipMenu() end },
    { id = "alpha_btn", cat = "prop",
      -- v62:短按=弹透明度设置,长按=切换 ☑随机(与灰度/粗细同套路,和笔触并排)
      text_fn = function(s)
          return "透明度(" .. (s.alpha_random and "☑" or "☐") .. "随机)"
      end,
      on_tap = function(s)
          -- 同灰度:选中对象时保持选中走元素级调节;无选中弹全局设置,不切当前工具
          s:_pickAlpha()
      end,
      on_hold = function(s) s:_toggleAlphaRandom() end },
    -- 图层类(v59f:每层单条目 —— ●当前层 + ☐/☑隐藏;单击=切层选中,长按=切隐藏)
    { id = "layer3_btn", cat = "layer", close_on_tap = false,
      text_fn = function(s)
          local mark = (s.active_layer == 3 and "●" or "○")
          local vis = (s.layer_visible[3] and "☐" or "☑")
          return mark .. "上图层(" .. vis .. "隐藏)"
      end,
      active_fn = function(s) return s.active_layer == 3 end,
      on_tap = function(s) s:_switchLayer(3) end,
      on_hold = function(s) s:_toggleLayerVisibleOf(3) end },
    { id = "layer2_btn", cat = "layer", close_on_tap = false,
      text_fn = function(s)
          local mark = (s.active_layer == 2 and "●" or "○")
          local vis = (s.layer_visible[2] and "☐" or "☑")
          return mark .. "中图层(" .. vis .. "隐藏)"
      end,
      active_fn = function(s) return s.active_layer == 2 end,
      on_tap = function(s) s:_switchLayer(2) end,
      on_hold = function(s) s:_toggleLayerVisibleOf(2) end },
    { id = "layer1_btn", cat = "layer", close_on_tap = false,
      text_fn = function(s)
          local mark = (s.active_layer == 1 and "●" or "○")
          local vis = (s.layer_visible[1] and "☐" or "☑")
          return mark .. "下图层(" .. vis .. "隐藏)"
      end,
      active_fn = function(s) return s.active_layer == 1 end,
      on_tap = function(s) s:_switchLayer(1) end,
      on_hold = function(s) s:_toggleLayerVisibleOf(1) end },
    { id = "layer_alpha_btn", cat = "layer", close_on_tap = true,
      -- v62:当前层整体透明度(草稿层整体调淡);文本带当前值
      text_fn = function(s)
          local v = (s.layer_alpha and s.layer_alpha[s.active_layer]) or 1
          return "当前层透明度 " .. math.floor(v * 100 + 0.5) .. "%"
      end,
      on_tap = function(s) s:_pickLayerAlpha() end },
    -- 功能类(点选后面板保持打开,撤销/重做/清空可连点;退出/关于 v59d 并入)
    { id = "undo_btn",  cat = "func", label = "撤销",
      on_tap = function(s) s:_undo() end },
    { id = "redo_btn",  cat = "func", label = "重做",
      on_tap = function(s) s:_redo() end },
    { id = "clear_btn", cat = "func", label = "清空",
      on_tap = function(s) s:_clearAll() end },
    -- v62d:保存=工程文件(.drawing,可重新打开继续编辑);输出=导出 PNG
    -- v62e 排序(左→右,上→下):撤销 重做 / 清空 打开 / 输出 保存 / 关于 退出
    { id = "open_proj_btn", cat = "func", label = "打开", close_on_tap = true,
      on_tap = function(s) s:_openProject() end },
    { id = "save_btn",  cat = "func", label = "输出", close_on_tap = true,
      on_tap = function(s) s:_save() end },
    { id = "save_proj_btn", cat = "func", label = "保存", close_on_tap = true,
      on_tap = function(s) s:_saveProject() end },
    { id = "about_btn", cat = "func", label = "关于",
      on_tap = function(s)
          -- 先关功能面板再弹关于,避免面板还开着盖在底下(弹窗/面板互斥)
          if s._category_popup then
              UIManager:close(s._category_popup, "full")
          end
          s:_showAbout()
      end },
    { id = "exit_btn",  cat = "func", label = "退出",
      on_tap = function(s) s:_onClose() end },
}
M._toggle_buttons = TOGGLE_BUTTONS

-- 生成单个面板条目定义:id/文字/单击(不含关面板逻辑,由 _showCategoryMenu 统一包装)。
-- v59e:带 on_hold 的条目生成 hold_callback(长按切勾选:矩实/圆实/框擦/灰度随机/粗细随机)
function M:_toggleDef(t)
    local def = {
        id = t.id,
        text = t.text_fn and t.text_fn(self) or t.label,
        callback = function()
            t.on_tap(self)
        end,
    }
    if t.enabled_fn then
        -- v59f:动态可用性(如"字体"选中文字对象才可点);Button enabled=false 自动灰显
        def.enabled = t.enabled_fn(self)
    end
    if t.on_hold then
        def.hold_callback = function()
            -- 长按勾选切换:短按已切勾选工具的,长按再切一次进勾选态
            t.on_hold(self)
            -- 面板保持打开,勾选文字变了必须显式刷 EPD:
            -- Button:setText 只改内存 widget,真机墨水屏不刷新看起来"无反应"
            if self._panel_bt then
                UIManager:setDirty(self._panel_bt, "partial")
            end
        end
    end
    return def
end

-- 构造某分类的 ButtonTable(不弹出;_showCategoryMenu 与测试共用)。
-- 每行两个条目(面板紧凑,13 个工具条目单列会超屏);底色规则:工具类激活条目浅灰,其余一律白底。
function M:_categoryBt(cat)
    local defs = {}
    for _, t in ipairs(TOGGLE_BUTTONS) do
        if t.cat == cat then
            defs[#defs + 1] = self:_toggleDef(t)
        end
    end
    local rows = {}
    -- v59h:图层分类每行1个(3 按钮垂直对齐一列,宽度统一);其余分类每行2个紧凑排布
    local step = (cat == "layer") and 1 or 2
    for i = 1, #defs, step do
        if step == 1 then
            rows[#rows + 1] = { defs[i] }
        else
            rows[#rows + 1] = { defs[i], defs[i + 1] } -- 末行可能只有 1 个
        end
    end
    local bt = ButtonTable:new{
        width = math.floor(Screen:getWidth() * const.UI_WIDTH_MEDIUM),
        buttons = rows,
    }
    for _, t in ipairs(TOGGLE_BUTTONS) do
        if t.cat == cat then
            local b = bt.button_by_id[t.id]
            if b and b[1] then
                local active = (cat == "tool" or cat == "layer")
                    and t.active_fn and t.active_fn(self)
                b[1].background = active and Blitbuffer.COLOR_LIGHT_GRAY
                    or Blitbuffer.COLOR_WHITE
            end
        end
    end
    return bt
end

local CATEGORY_TITLES = { tool = "工具", prop = "属性设置", layer = "图层", func = "功能" }

-- 弹出分类面板(居中圆角可拖动,点空白关闭)。
-- v59:记录 _open_cat 供底栏断线指示;重复点其他分类先关旧面板;关闭时还原横线
function M:_showCategoryMenu(cat)
    local popup
    local bt
    bt = self:_categoryBt(cat)
    -- 条目单击回调通过 get_popup 拿到本面板,按需关闭
    for _, t in ipairs(TOGGLE_BUTTONS) do
        if t.cat == cat then
            local b = bt.button_by_id[t.id]
            if b then
                local orig = b.callback
                local close = t.close_on_tap
                if close == nil then
                    -- 功能类/图层类保持打开(连点/单选勾选状态即时可见)
                    close = (t.cat ~= "func" and t.cat ~= "layer")
                end
                b.callback = function()
                    orig()
                    if close and popup then
                        UIManager:close(popup, "full")
                    end
                end
            end
        end
    end
    self._panel_bt = bt
    -- 面板互斥:换分类时先关旧面板(其 onCloseWidget 会清 _open_cat)
    if self._category_popup then
        UIManager:close(self._category_popup, "full")
        self._category_popup = nil
    end
    self._open_cat = cat
    self:_refreshToolbar()
    popup = components.showCenteredDialog{
        name = "DrawingCategoryMenu",
        title = CATEGORY_TITLES[cat] or cat,
        content = bt,
        log = function(...) self:_log(...) end,
    }
    self._category_popup = popup
    local canvas = self
    local orig_close = popup.onCloseWidget
    function popup:onCloseWidget()
        if canvas._open_cat == cat then
            canvas._open_cat = nil
            canvas._category_popup = nil
            canvas:_refreshToolbar()
        end
        if orig_close then
            orig_close(self)
        end
    end
    self:_log("category menu shown:", cat)
end

-- 最小化时左上角悬浮的"菜单"恢复按钮:
-- 宽度 = 工具栏第一格(隐藏按钮所在格,v59c 隐藏移到最左)宽度,对齐
function M:_buildRestoreButton()
    -- 与底栏同风格:线框上箭头图标按钮(隐藏键的下箭头成对),等宽一格悬浮左上
    local icon_px = Screen:scaleBySize(const.TOOLBAR_ICON_PX)
    local row_h = icon_px + 2 * Size.padding.default
    local btn = Button:new{
        icon = "dw.chevron.up",
        icon_width = icon_px,
        icon_height = icon_px,
        bordersize = 0,
        callback = function() self:_toggleMinimize() end,
    }
    self.restore_btn = self:_toolbarCell(btn, math.floor(Screen:getWidth() / #const.TOOLBAR_ICONS), row_h)
end

-- 面板动态状态(v59b):text_fn 条目刷文字;v61f 起底色也随 active_fn 实时刷新
-- (切层/切工具后打开着的面板高亮跟手,与 _categoryBt 构造时同一套规则)
function M:_syncToolLabels()
    local bt = self._panel_bt
    if not bt or not bt.button_by_id then
        return
    end
    for _, t in ipairs(self._toggle_buttons or {}) do
        local b = bt.button_by_id[t.id]
        if b then
            if t.text_fn and b.setText then
                b:setText(t.text_fn(self), b.width)
            end
            if b[1] then
                local active = (t.cat == "tool" or t.cat == "layer")
                    and t.active_fn and t.active_fn(self)
                b[1].background = active and Blitbuffer.COLOR_LIGHT_GRAY
                    or Blitbuffer.COLOR_WHITE
            end
        end
    end
end

-- ============================ 状态栏 ============================

-- 默认字体:从 fonts 目录取,优先带 CJK 的(中文输入友好);取不到退回 cfont
function M:_defaultFont()
    local ok, list = pcall(function()
        local FontList = require("fontlist")
        return FontList:getFontList()
    end)
    if ok and list and #list > 0 then
        for _, path in ipairs(list) do
            local base = path:match("[^/\\]+$") or ""
            if base:lower():match("cjk") then
                return base
            end
        end
        return (list[1]:match("[^/\\]+$"))
    end
    return "cfont"
end

-- 状态栏文本:显示"下次落笔"的状态——工具/模式 + 灰度(是否随机) + 粗细(是否随机) + 当前图层
function M:_statusText()
    local t = self.tool
    local gray_txt
    if self.gray_random then
        gray_txt = string.format("灰:随机(%d-%d,%d级)",
            math.floor(self.gray_min * 100 + 0.5), math.floor(self.gray_max * 100 + 0.5), self.gray_levels)
    else
        gray_txt = string.format("灰:%d%%", math.floor(self.gray * 100 + 0.5))
    end
    local width_txt
    if self.width_random then
        width_txt = string.format("粗:随机(%d-%d,%d级)", self.width_min, self.width_max, self.width_levels)
    else
        width_txt = string.format("粗:%d", self.width)
    end
    local layer_txt = const.LAYER_NAMES[self.active_layer]
        .. (self.layer_visible[self.active_layer] and "" or "(隐)")
    -- 透明度(下次落笔):随机或非全不透明时才显示,省状态栏宽度
    if self.alpha_random then
        layer_txt = layer_txt .. string.format(" 透:随机(%d-%d)",
            math.floor((self.alpha_min or 0.3) * 100 + 0.5), math.floor((self.alpha_max or 1) * 100 + 0.5))
    elseif (self.alpha or 1) < 0.999 then
        layer_txt = layer_txt .. string.format(" 透:%d%%", math.floor(self.alpha * 100 + 0.5))
    end
    local base
    if t == "text" then
        -- 文字:灰度值/字号/字体名/图层
        local fname = (self.font or "?"):gsub("%.[^.]+$", "")
        base = string.format("%s %s 字号:%d %s %s", const.TOOL_NAMES[t], gray_txt, self.font_size, fname, layer_txt)
    elseif t == "eraser" then
        local mode = (self.eraser_mode == "rect") and "框选删" or "画笔删"
        base = string.format("%s(%s) %s %s", const.TOOL_NAMES[t], mode, width_txt, layer_txt)
    elseif t == "fill" then
        local mode = (self.fill_mode == "path") and "描边填" or "点填"
        base = string.format("%s(%s) %s %s", const.TOOL_NAMES[t], mode, gray_txt, layer_txt)
    elseif t == "select" then
        local mode = (self.select_mode == "copy") and "复制" or "移动"
        base = string.format("选择(%s) %s", mode, layer_txt)
    elseif t == "rect" or t == "circle" then
        local filled = ((t == "rect" and self.rect_filled) or (t == "circle" and self.circle_filled))
            and "实心" or "空心"
        base = string.format("%s(%s) %s %s %s", const.TOOL_NAMES[t], filled, gray_txt, width_txt, layer_txt)
    else
        -- 画笔/直线显示笔触形状(下次落笔状态的一部分)
        local tip_txt = (t == "brush" or t == "line") and (" 尖:" .. (const.TIP_NAMES[self.tip] or "圆")) or ""
        base = string.format("%s %s %s%s %s", const.TOOL_NAMES[t] or t, gray_txt, width_txt, tip_txt, layer_txt)
    end
    return base
end

function M:_updateStatus()
    self._status = self:_statusText()
    UIManager:setDirty(self, "partial")
end

-- ============================ 居中按钮弹窗 ============================

-- 居中按钮弹窗(图层菜单/灰度设置/粗细设置共用)。
-- KOReader 的 Menu 条目左对齐无法居中,这里用 ButtonTable(按钮文字天然居中)
-- 包在全屏模态容器里,点空白处关闭。返回 bt(可 button_by_id 改标签)、popup
function M:_showCenteredButtons(title, buttons, width_factor)
    -- 统一走 components.showCenteredDialog(圆角可拖动面板 + 点空白关闭);
    -- 返回 bt(可 button_by_id 改标签)、popup
    local bt = ButtonTable:new{
        width = math.floor(Screen:getWidth() * (width_factor or const.UI_WIDTH_MEDIUM)),
        buttons = buttons,
    }
    local popup = components.showCenteredDialog{
        name = "DrawingCenterMenu",
        title = title,
        content = bt,
        log = function(...) self:_log(...) end,
    }
    return bt, popup
end

-- 笔触选择弹窗(居中,带图形预览):7 种笔触,点选设 self.tip 并关闭。
-- wbuilder/WSL 字体集与 Kindle 不同:Font:getFace("infont",20) 可能返回 nil,
-- nil face 进 TextWidget 会在首次 paintTo/getSize 时 nil 解引用静默崩(坑 14c)。
-- 本函数全程防御:字体判空回退 + 每行 Blitbuffer/ImageWidget 构造包 pcall + 整函数 pcall 兜底。
function M:_showTipMenu()
    -- 外层 pcall:防首 paint 异常;失败时给可见反馈,而非静默无反应。
    -- 风格与图层/灰度弹窗一致(圆角可拖动面板,showCenteredDialog),
    -- 文字统一用 _defaultFont()(与状态栏同源),不硬编码 infont。
    local ok, err = pcall(M._showTipMenu_core, self)
    if not ok then
        local ok2, msg = pcall(tostring, err)
        self:_log("tip menu error:", ok2 and msg or "(无法序列化错误对象)")
        components.showToast("笔触菜单打开失败", 2)
    end
end

function M._showTipMenu_core(self)
    -- 布局:每行 = ImageWidget(笔触形状预览) + 原生 Button(文字标签),VerticalGroup 居中。
    -- 点触全部交给原生 Button 自带手势(工具栏/图层菜单同源,wbuilder 已验证),
    -- 不用自定义 tapRow/GestureRange;预览用裸 Blitbuffer 的 ImageWidget
    -- (Button.icon 只认图标名不认 BB,且 text 分支优先会忽略 icon,所以放行外)。
    local Button = require("ui/widget/button")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local icon_px = Screen:scaleBySize(28)
    local row_h = Screen:scaleBySize(40)
    -- 图标与文字紧贴(按钮文字左对齐,避免固定宽按钮把文字推远产生大空隙)
    local gap_w = Screen:scaleBySize(4)
    local btn_w = math.floor(Screen:getWidth() * const.UI_WIDTH_NARROW)
    -- 行间细分隔线(浅灰,比按钮默认边框更雅致)
    local sep_w = icon_px + gap_w + btn_w
    local function separator()
        return VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Screen:scaleBySize(5) },
            LineWidget:new{
                dimen = Geom:new{ w = sep_w, h = math.max(1, Screen:scaleBySize(1)) },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(5) },
        }
    end
    local popup
    local function closePopup()
        if popup then UIManager:close(popup, "full") end
    end
    local rows = {}
    for _, t in ipairs(const.TIPS) do
        local tip_name, tip_label = t[1], t[2]
        -- 预览:小画布画笔触形状 -> Blitbuffer(ImageWidget 接管所有权,不再 :free);
        -- 单行预览失败只丢该行图形,不影响文字与点选。
        local img_widget
        pcall(function()
            local pv = Blitbuffer.new(icon_px, icon_px, Blitbuffer.TYPE_BB8)
            pv:paintRect(0, 0, icon_px, icon_px, Blitbuffer.COLOR_WHITE)
            shapes.tip(pv, math.floor(icon_px / 2), math.floor(icon_px / 2),
                math.floor(icon_px * 0.55), Blitbuffer.gray(1.0), tip_name)
            img_widget = ImageWidget:new{ image = pv, width = icon_px, height = icon_px }
        end)
        local btn = Button:new{
            text = tip_label,
            width = btn_w,
            bordersize = 0,
            align = "left",
            callback = function()
                self.tip = tip_name
                self:_updateStatus()
                self:_log("tip ->", tip_name)
                closePopup()
            end,
        }
        local row_content
        if img_widget then
            row_content = HorizontalGroup:new{
                FrameContainer:new{
                    dimen = Geom:new{ w = icon_px, h = row_h },
                    bordersize = 0, padding = 0, margin = 0,
                    img_widget,
                },
                HorizontalSpan:new{ width = gap_w },
                FrameContainer:new{
                    dimen = Geom:new{ w = btn_w, h = row_h },
                    bordersize = 0, padding = 0, margin = 0,
                    btn,
                },
            }
        else
            row_content = btn
        end
        -- 行间细分隔线:首行前不加,其余每行前加一条
        if #rows > 0 then
            rows[#rows + 1] = separator()
        end
        rows[#rows + 1] = row_content
    end
    -- 关闭行(无边框、宽度自适应,整体在面板内居中;文案与其它弹窗统一为"关闭")
    rows[#rows + 1] = separator()
    rows[#rows + 1] = Button:new{
        text = _("关闭"),
        bordersize = 0,
        callback = function()
            closePopup()
        end,
    }
    popup = components.showCenteredDialog{
        name = "DrawingTipMenu",
        content = VerticalGroup:new{ align = "center", unpack(rows) },
        log = function(...)
            local parts = {}
            for _, v in ipairs({...}) do
                local ok2, r = pcall(tostring, v)
                parts[#parts + 1] = ok2 and r or "(无法序列化)"
            end
            local msg = table.concat(parts, " ")
            self:_log(msg)
            if msg:find("error") then
                pcall(function()
                    local f = io.open("/tmp/drawingpad_tip_he_error.txt", "a")
                    if f then f:write(msg .. "\n"); f:close() end
                end)
            end
        end,
    }
    -- paintTo 崩溃防护(坑 14c),覆盖后续 repaint
    if popup and popup.paintTo then
        local orig_paintTo = popup.paintTo
        function popup:paintTo(...)
            local ok, res = pcall(orig_paintTo, self, ...)
            if not ok then
                local msg = "tip menu paintTo error: " .. tostring(res)
                self:_log(msg)
                components.showToast("笔触菜单渲染失败", 2)
            end
            return res
        end
    end
    self:_log("tip menu shown")
end

-- ============================ 文字插入 ============================

-- 文字插入/编辑对话框。
-- el 存在 = 编辑已存在的文字元素(选中文字 → 点"文字"工具 → 属性修改:内容/字体/字号),
-- 预填当前内容与字体信息,确认后 _updateTextElement 更新元素(可撤销);
-- el 为 nil = 插入新文字,输入框自动填入上次输入的内容,字体/字号恢复上次提交的值
function M:_showTextDialog(x, y, el)
    local self_widget = self
    local is_edit = el ~= nil
    local dlg
    if is_edit then
        -- 编辑模式:字体/字号切到对象当前值(按钮显示/修改对象属性);
        -- 快照原始属性:编辑期间 字体/字号 实时应用到元素(no_undo),
        -- 关闭(更新/取消)时统一用快照写一条 transform 撤销
        self.font = el.font
        self.font_size = el.size
        self._text_edit_orig = self:_cloneElement(el)
    elseif self._last_font then
        -- 插入模式:自动恢复上次输入使用的字体信息
        self.font = self._last_font
        self.font_size = self._last_font_size
        self._text_edit_orig = nil
    end
    -- 字体/字号按钮:选中后实时更新弹窗内按钮标签
    local function fontLabel()
        return "字体: " .. ((self.font or "?"):gsub("%.[^.]+$", ""))
    end
    local function updateFontLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["font_btn"]
        if btn and btn.setText then
            btn:setText(fontLabel(), btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    local function updateSizeLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["size_btn"]
        if btn and btn.setText then
            btn:setText("字号: " .. self.font_size, btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    dlg = InputDialog:new{
        title = is_edit and _("修改文字") or _("插入文字"),
        input = (is_edit and el.text) or (self._last_text or ""),
        input_hint = is_edit and _("修改文字内容(字体/字号用下方按钮)")
            or _("输入要插入的文字(灰度用工具栏调整)"),
        buttons = {
            {
                -- 字体/字号整合进文字弹窗
                { id = "font_btn", text = fontLabel(),
                  callback = function() self_widget:_pickFont(updateFontLabel) end },
                { id = "size_btn", text = "字号: " .. self.font_size,
                  callback = function() self_widget:_pickFontSize(updateSizeLabel) end },
            },
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dlg)
                    end,
                },
                {
                    text = is_edit and _("更新") or _("插入"),
                    is_enter_default = true,
                    callback = function()
                        local text = dlg:getInputText()
                        -- 先应用再关闭:编辑期间的实时属性改动已落在元素上,
                        -- _updateTextElement 用 _text_edit_orig 快照写撤销;
                        -- 先关闭会让 onCloseWidget 抢先看到快照,造成重复撤销
                        if is_edit then
                            self_widget:_updateTextElement(el, text)
                        else
                            self_widget:_commitText(x, y, text)
                        end
                        UIManager:close(dlg)
                    end,
                },
            },
        },
    }
    -- 对话框按钮即时响应(去掉 flash_ui 阻塞,公共组件)
    components.instantButtons(dlg.button_table)
    -- 未点"更新"关闭(取消/返回键/点外部)时:编辑期间实时改过文字属性 → 补写撤销
    local orig_dlg_close = dlg.onCloseWidget
    function dlg:onCloseWidget()
        if self_widget._text_edit_orig then
            local sel = self_widget._selected
            if sel and sel.kind == "text" then
                local orig = self_widget._text_edit_orig
                local final = self_widget:_cloneElement(sel)
                if orig.text ~= final.text or orig.font ~= final.font or orig.size ~= final.size then
                    self_widget:_pushUndo({ kind = "transform", el = sel, orig = orig, final = final })
                    self_widget:_clearRedo()
                    self_widget:_log("text edit closed w/o update, undo recorded")
                end
            end
            self_widget._text_edit_orig = nil
        end
        if orig_dlg_close then
            orig_dlg_close(self)
        end
    end
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- 修改已存在的文字元素(内容/字体/字号,可撤销,旧∪新区域重绘)。
-- 编辑期间 字体/字号 已实时应用到元素(no_undo),_text_edit_orig 是打开弹窗时的快照,
-- 撤销从快照到最终值(覆盖实时改动全程)
function M:_updateTextElement(el, text)
    if not el or el.kind ~= "text" then
        return
    end
    text = text or ""
    if text == "" then
        self:_log("text edit empty, skipped")
        return
    end
    local orig = self._text_edit_orig or self:_cloneElement(el)
    local old_region = self:_elementRegion(el)
    el.text = text
    el.font = self.font
    el.size = self.font_size
    self:_cacheBBox(el)
    local final = self:_cloneElement(el)
    self._text_edit_orig = nil
    if orig.text == final.text and orig.font == final.font and orig.size == final.size then
        return -- 无变化(含实时改回原值)
    end
    local region = self:_mergeRegions(old_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    UIManager:setDirty(self, "ui", region)
    self:_pushUndo({ kind = "transform", el = el, orig = orig, final = final })
    self:_clearRedo()
    self:_log("update text", string.format("%q", text), "font", self.font, self.font_size)
end

-- 编辑文字中:实时应用 字体/字号 到选中文字元素(逐 tick 调用,不写撤销;
-- 撤销统一由 _updateTextElement/onCloseWidget 用 _text_edit_orig 快照写一条)
function M:_applySelectedTextStyle()
    local el = self._selected
    if not el or el.kind ~= "text" then
        return
    end
    if el.font == self.font and el.size == self.font_size then
        return
    end
    local old_region = self:_elementRegion(el)
    el.font = self.font
    el.size = self.font_size
    self:_cacheBBox(el)
    local region = self:_mergeRegions(old_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    UIManager:setDirty(self, "ui", region)
    self:_log("text style live ->", self.font, self.font_size)
end

-- 选中文字对象 → 属性修改菜单入口(点"文字"工具触发,见 _setTool)
function M:_editSelectedText()
    local el = self._selected
    if not el or el.kind ~= "text" then
        return
    end
    self:_showTextDialog(el.x or 0, el.y or 0, el)
end

function M:_commitText(x, y, text)
    if not text or text == "" then
        self:_log("text empty, skipped")
        return
    end
    -- 纯空白(空格/tab/换行)视为取消:渲染不可见却占元素/bbox,徒增困惑
    if not text:find("%S") then
        self:_log("text whitespace-only, skipped")
        return
    end
    -- 记住本次输入的内容与字体信息:下次点文字工具自动填入
    self._last_text = text
    self._last_font = self.font
    self._last_font_size = self.font_size
    local el = {
        kind = "text",
        x = x, y = y,
        text = text,
        font = self.font,
        size = self.font_size,
        gray = self:_resolveGray(),
        alpha = self:_resolveAlpha(),
    }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    self:_drawTextTo(self.canvas_bb, el)
    self:_log("commit text", string.format("%q", text), "at", x, y,
        "font", self.font, self.font_size, "gray", self.gray)
    -- 上方有可见图层时重放提交区域:直接画进 canvas_bb 的文字不能压住高层墨迹
    local region = self:_elementRegion(el)
    self:_commitRegionReplay(region)
    UIManager:setDirty(self, "partial", region)
end

function M:_drawTextTo(bb, el, layer_idx)
    if not el or not el.text or el.text == "" or not el.font or not el.size then
        return
    end
    local face = Font:getFace(el.font, el.size)
    if not face then
        -- 字体文件缺失时 getFace 返回 nil:跳过绘制,不再把 nil face 传给
        -- renderUtf8Text(旧版直接抛 Lua 错误冒泡导致整机退出)
        self:_log("draw text skipped: no face for", el.font, el.size)
        return
    end
    local rot = el.rot or 0
    local sx = el.sx or 1
    local sy = el.sy or 1
    -- 有效透明度 = 元素 × 所在层(缺省当前层);<1 时走临时 BB 逐像素混合路径
    local alpha = (el.alpha or 1)
        * ((self.layer_alpha and self.layer_alpha[layer_idx or self.active_layer]) or 1)
    -- 基线取插入点向下约 0.8 字号,让文字主体落在点击点附近
    local baseline = (el.y or 0) + math.floor(el.size * 0.8)
    if rot == 0 and sx == 1 and sy == 1 and alpha >= 0.999 then
        RenderText:renderUtf8Text(bb, el.x or 0, baseline,
            face, el.text,
            false, false, Blitbuffer.gray(el.gray))
        return
    end
    -- 拉伸/旋转:渲染到临时 BB → 按 (sx,sy) 缩放 → 绕锚点(基线左端)逐像素逆变换采样
    local s = RenderText:sizeUtf8Text(0, nil, face, el.text, false, false)
    if not (s and s.x and s.y_top and s.y_bottom) then
        return
    end
    local w, h = s.x, s.y_top + s.y_bottom
    local temp = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    temp:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    -- 半透明:临时 BB 用纯黑渲染(墨量 m=(255-像素)/255 可精确反解),写回时按 alpha 混合;
    -- 不透明:照常按元素灰度渲染,写回即正常文字
    RenderText:renderUtf8Text(temp, 0, s.y_top, face, el.text, false, false,
        (alpha < 0.999) and Blitbuffer.gray(1.0) or Blitbuffer.gray(el.gray))
    -- 缩放后尺寸与锚点(基线左端)在缩放局部系的位置
    local dw = math.max(1, math.floor(w * sx + 0.5))
    local dh = math.max(1, math.floor(h * sy + 0.5))
    -- 锚点 = 基线左端(与 _textExtent/_frameCorners 同语义:基线 = el.y + 0.8*字号)。
    -- 旧版把 el.y 直接当基线,旋转/拉伸后的文字整体上偏 0.8*字号,与选取框错位
    local ax = el.x or 0
    local ay = (el.y or 0) + math.floor(el.size * 0.8)
    local ayl = math.floor(s.y_top * sy + 0.5)
    -- 缩放矩形绕锚点旋转后的外接范围
    local c, sn = math.cos(rot), math.sin(rot)
    local x0, y0 = 0, -ayl
    local x1, y1 = dw, dh - ayl
    local hw = math.max(math.abs(x0 * c - y0 * sn), math.abs(x1 * c - y0 * sn),
        math.abs(x1 * c - y1 * sn), math.abs(x0 * c - y1 * sn))
    local hh = math.max(math.abs(x0 * sn + y0 * c), math.abs(x1 * sn + y0 * c),
        math.abs(x1 * sn + y1 * c), math.abs(x0 * sn + y1 * c))
    local x_min, x_max = math.max(0, math.floor(ax - hw)), math.min(bb:getWidth() - 1, math.ceil(ax + hw))
    local y_min, y_max = math.max(0, math.floor(ay - hh)), math.min(bb:getHeight() - 1, math.ceil(ay + hh))
    for py = y_min, y_max do
        for px = x_min, x_max do
            -- 逆旋转到缩放局部系,再逆缩放到自然系
            local lx = (px - ax) * c + (py - ay) * sn
            local ly = -(px - ax) * sn + (py - ay) * c + ayl
            local xi = math.floor(lx / sx + 0.5)
            local yi = math.floor(ly / sy + 0.5)
            if xi >= 0 and xi < w and yi >= 0 and yi < h then
                local pv = temp:getPixel(xi, yi)
                local a8 = pv and pv.a
                if a8 and a8 < 255 then
                    if alpha < 0.999 then
                        -- 墨量 m=(255−a8)/255,把墨色按"m·α 不透明度"合成到 dest
                        -- (out = dest·(1−mα) + 墨色·mα)。直接用原生 setPixelBlend:
                        -- 不读 dest 像素(拖拽预览的 bb 是屏幕帧缓冲,模拟器为
                        -- ColorRGB32,读 .a 会崩),且 BB8/RGB32 各类型都正确
                        local coverage = math.floor((255 - a8) * alpha + 0.5)
                        if coverage > 0 then
                            bb:setPixelBlend(px, py, Blitbuffer.Color8A(
                                math.floor(255 * (1 - (el.gray or 1)) + 0.5), coverage))
                        end
                    else
                        bb:setPixel(px, py, Blitbuffer.Color8(a8))
                    end
                end
            end
        end
    end
    temp:free()
end

-- ============================ 调色板 / 粗细 / 字体 / 字号 ============================

-- 数值调节弹窗(滑条 + 预设档位,替代 SpinWidget 的虚拟键盘数字输入——触屏输入不便)。
-- 结构:标题 + 大号当前值 + 可拖动/点按定位的滑条(带刻度)+ 预设档位一键选 + 关闭。
-- 拖动节流参考 KOReader 亮度调节(FrontLightWidget):拖动中限速应用与刷新,pan_release 补终态。
-- opts: { title, value, min, max, unit, presets, onchange(v), onclose(v) }
-- onchange 在值变化时调用(实时应用,调用方按 no_undo 语义处理);onclose 在关闭时调用(写撤销等)
-- 实现已迁入 components.showValuePicker(组件库统一维护)
function M:_showValuePicker(opts)
    opts = opts or {}
    opts.log = function(...) self:_log(...) end
    return components.showValuePicker(opts)
end

-- 灰度/粗细设置弹窗共用生成器(v59 合并,结构/文案/布局一致,仅值域/单位/措辞不同)。
-- 随机模式只在属性面板条目长按切换(灰度(☑随机)/粗细(☑随机)),弹窗内无随机键无提示。
-- opts: { title, ids={4个按钮id}, labels={max,min}, get/set={max,min,levels,fixed},
--         spin={max={标题,min,max},...}, disp(v)→显示串 }
function M:_showSettingDialog(o)
    local popup
    local function labels()
        local l = {
            string.format("%s:%s", o.labels.max, o.disp(o.get.max(self))),
            string.format("%s:%s", o.labels.min, o.disp(o.get.min(self))),
            string.format("分级:%d", o.get.levels(self)),
            string.format("固定:%s", o.disp(o.get.fixed(self))),
        }
        return l
    end
    local bt
    local function refreshLabels()
        if not bt or not bt.button_by_id then
            return
        end
        local l = labels()
        for i, id in ipairs(o.ids) do
            local b = bt.button_by_id[id]
            if b and b.setText then
                b:setText(l[i], b.width)
            end
        end
        if popup then
            UIManager:setDirty(popup, "partial")
        end
    end
    local function spinval(key)
        -- 滑条初始值:内部值经 spin_val 映射成显示值(灰度 0-1 → 0-100);缺省 = 内部值
        local f = o.spin_val and o.spin_val[key]
        return f and f(self) or o.get[key](self)
    end
    local function spin(spec, onchange)
        self:_showValuePicker{
            title = spec[1],
            value = spec[4],
            min = spec[2],
            max = spec[3],
            onchange = function(v)
                onchange(v)
                refreshLabels()
            end,
        }
    end
    local btns = {
        {
            { id = o.ids[1], text = o.labels.max,
              callback = function()
                  local s = o.spin.max
                  spin({ s[1], s[2], s[3], spinval("max") }, function(v) o.set.max(self, v) end)
              end },
            { id = o.ids[2], text = o.labels.min,
              callback = function()
                  local s = o.spin.min
                  spin({ s[1], s[2], s[3], spinval("min") }, function(v) o.set.min(self, v) end)
              end },
        },
        {
            { id = o.ids[3], text = "分级",
              callback = function()
                  local s = o.spin.levels
                  spin({ s[1], s[2], s[3], spinval("levels") }, function(v) o.set.levels(self, v) end)
              end },
            { id = o.ids[4], text = "固定",
              callback = function()
                  local s = o.spin.fixed
                  spin({ s[1], s[2], s[3], spinval("fixed") }, function(v) o.set.fixed(self, v) end)
              end },
        },
        {
            { text = _("关闭"), callback = function() if popup then UIManager:close(popup, "full") end end },
        },
    }
    bt, popup = self:_showCenteredButtons(o.title, btns, const.UI_WIDTH_MEDIUM)
    refreshLabels()
end

-- 灰度设置弹窗:最大/最小/分级数(2-256)/固定灰度(内部 0-1,显示与输入 0-100%)
function M:_pickGray()
    if self.tool == "select" and self._selected then
        return self:_pickElementGray()
    end
    local function pct(v) return math.floor(v * 100 + 0.5) end
    self:_showSettingDialog{
        title = _("灰度"),
        ids = { "gray_max_btn", "gray_min_btn", "gray_levels_btn", "gray_fixed_btn" },
        labels = { max = _("最大"), min = _("最小") },
        get = {
            max = function(s) return s.gray_max end,
            min = function(s) return s.gray_min end,
            levels = function(s) return s.gray_levels end,
            fixed = function(s) return s.gray end,
        },
        set = {
            max = function(s, v) s.gray_max = v / 100 end,
            min = function(s, v) s.gray_min = v / 100 end,
            levels = function(s, v) s.gray_levels = v end,
            fixed = function(s, v) s.gray = v / 100 end,
        },
        spin = {
            max = { _("最大灰度(0%=白 100%=黑)"), 0, 100 },
            min = { _("最小灰度(0%=白 100%=黑)"), 0, 100 },
            levels = { _("随机分级数(2-256)"), 2, 256 },
            fixed = { _("固定灰度(0%=白 100%=黑)"), 0, 100 },
        },
        disp = function(v) return string.format("%d%%", pct(v)) end,
        spin_val = {
            max = function(s) return pct(s.gray_max) end,
            min = function(s) return pct(s.gray_min) end,
            fixed = function(s) return pct(s.gray) end,
        },
    }
    self:_log("gray dialog", self.gray_random and "random" or "fixed")
end

-- 选中对象灰度调节(选择工具 + 有选中对象时点"灰度"):滑条+预设档位,无中间确认。
-- 逐 tick 实时应用(no_undo 不写撤销),关闭时统一写一条撤销记录
function M:_pickElementGray()
    local el = self._selected
    if not el then
        return
    end
    local pending_orig = nil
    self:_showValuePicker{
        title = _("选中对象灰度(0%=白 100%=黑)"),
        value = math.floor((el.gray or 1) * 100 + 0.5),
        min = 0,
        max = 100,
        unit = "%",
        onchange = function(v)
            if self._selected ~= el then
                return
            end
            if not pending_orig then
                pending_orig = self:_cloneElement(el)
            end
            self:_applySelectedGray(v, true)
        end,
        onclose = function()
            if pending_orig and self._selected == el
                and math.abs((pending_orig.gray or 1) - (el.gray or 1)) > 0.001 then
                self:_pushUndo({ kind = "transform", el = el, orig = pending_orig, final = self:_cloneElement(el) })
                self:_clearRedo()
                self:_log("set selected gray", el.kind)
            end
        end,
    }
end

-- 选中对象线宽调节(文字/填充无线宽,提示后跳过)
function M:_pickElementWidth()
    local el = self._selected
    if not el then
        return
    end
    if el.kind == "text" or el.kind == "fill" then
        components.showToast(_("该对象没有线条粗细。"), 2)
        return
    end
    local pending_orig = nil
    self:_showValuePicker{
        title = _("选中对象粗细(px)"),
        value = el.width or 2,
        min = 1,
        max = 800,
        onchange = function(v)
            if self._selected ~= el then
                return
            end
            if not pending_orig then
                pending_orig = self:_cloneElement(el)
            end
            self:_applySelectedWidth(v, true)
        end,
        onclose = function()
            if pending_orig and self._selected == el and pending_orig.width ~= el.width then
                self:_pushUndo({ kind = "transform", el = el, orig = pending_orig, final = self:_cloneElement(el) })
                self:_clearRedo()
                self:_log("set selected width", el.kind)
            end
        end,
    }
end

-- 粗细设置弹窗:最粗/最细/分级数(2-256)/固定粗细(px)
function M:_pickWidth()
    if self.tool == "select" and self._selected then
        return self:_pickElementWidth()
    end
    self:_showSettingDialog{
        title = _("粗细"),
        ids = { "width_max_btn", "width_min_btn", "width_levels_btn", "width_fixed_btn" },
        labels = { max = _("最粗"), min = _("最细") },
        get = {
            max = function(s) return s.width_max end,
            min = function(s) return s.width_min end,
            levels = function(s) return s.width_levels end,
            fixed = function(s) return s.width end,
        },
        set = {
            max = function(s, v) s.width_max = v end,
            min = function(s, v) s.width_min = v end,
            levels = function(s, v) s.width_levels = v end,
            fixed = function(s, v) s.width = v end,
        },
        spin = {
            max = { _("最粗(px)"), 1, 800 },
            min = { _("最细(px)"), 1, 800 },
            levels = { _("随机分级数(2-256)"), 2, 256 },
            fixed = { _("固定粗细(px)"), 1, 800 },
        },
        disp = function(v) return string.format("%d", v) end,
    }
    self:_log("width dialog", self.width_random and "random" or "fixed")
end

-- 透明度设置弹窗:最浓/最淡/分级数(2-256)/固定透明度(内部 0-1,显示与输入 0-100%,100%=不透明)
function M:_pickAlpha()
    if self.tool == "select" and self._selected then
        return self:_pickElementAlpha()
    end
    local function pct(v) return math.floor(v * 100 + 0.5) end
    self:_showSettingDialog{
        title = _("透明度"),
        ids = { "alpha_max_btn", "alpha_min_btn", "alpha_levels_btn", "alpha_fixed_btn" },
        labels = { max = _("最浓"), min = _("最淡") },
        get = {
            max = function(s) return s.alpha_max end,
            min = function(s) return s.alpha_min end,
            levels = function(s) return s.alpha_levels end,
            fixed = function(s) return s.alpha end,
        },
        set = {
            max = function(s, v) s.alpha_max = v / 100 end,
            min = function(s, v) s.alpha_min = v / 100 end,
            levels = function(s, v) s.alpha_levels = v end,
            fixed = function(s, v) s.alpha = v / 100 end,
        },
        spin = {
            max = { "最浓(100%=不透明 0%=全透明)", 0, 100 },
            min = { "最淡(100%=不透明 0%=全透明)", 0, 100 },
            levels = { _("随机分级数(2-256)"), 2, 256 },
            fixed = { "固定透明度(100%=不透明)", 0, 100 },
        },
        disp = function(v) return string.format("%d%%", pct(v)) end,
        spin_val = {
            max = function(s) return pct(s.alpha_max) end,
            min = function(s) return pct(s.alpha_min) end,
            fixed = function(s) return pct(s.alpha) end,
        },
    }
    self:_log("alpha dialog", self.alpha_random and "random" or "fixed")
end

-- 选中对象透明度调节(选择工具 + 有选中对象时点"透明度"):滑条+预设档位,无中间确认。
-- 逐 tick 实时应用(no_undo 不写撤销),关闭时统一写一条撤销记录
function M:_pickElementAlpha()
    local el = self._selected
    if not el then
        return
    end
    local pending_orig = nil
    self:_showValuePicker{
        title = "选中对象透明度(100%=不透明)",
        value = math.floor((el.alpha or 1) * 100 + 0.5),
        min = 0,
        max = 100,
        unit = "%",
        onchange = function(v)
            if self._selected ~= el then
                return
            end
            if not pending_orig then
                pending_orig = self:_cloneElement(el)
            end
            self:_applySelectedAlpha(v, true)
        end,
        onclose = function()
            if pending_orig and self._selected == el
                and math.abs((pending_orig.alpha or 1) - (el.alpha or 1)) > 0.001 then
                self:_pushUndo({ kind = "transform", el = el, orig = pending_orig, final = self:_cloneElement(el) })
                self:_clearRedo()
                self:_log("set selected alpha", el.kind)
            end
        end,
    }
end

-- 字体选择:列出 KOReader fonts 目录下实际扫描到的字体(FontList,可滚动 Menu)
-- @param on_change 选中字体后的回调(文字插入弹窗用来刷新按钮标签)
function M:_pickFont(on_change)
    local FontList = require("fontlist")
    local Menu = require("ui/widget/menu")
    local list = FontList:getFontList()
    local menu -- 先声明,供条目回调直接关闭菜单(选中即关,不依赖 Menu 内部路径)
    local items = {}
    for _, path in ipairs(list) do
        local fname = path:match("[^/\\]+$")
        if fname then
            local display = FontList:getLocalizedFontName(path, 0)
                or (fname:gsub("%.[^.]+$", ""))
            table.insert(items, {
                text = display,
                callback = function()
                    self.font = fname
                    self:_applySelectedTextStyle() -- 编辑文字中:实时改选中文字元素的字体
                    self:_log("font ->", fname)
                    self:_updateStatus()
                    if on_change then
                        on_change()
                    end
                    if menu then
                        UIManager:close(menu) -- 选中字体后自动关闭
                    end
                end,
            })
        end
    end
    if #items == 0 then
        components.showToast(_("未找到可用字体(fonts 目录)。"), 2)
        return
    end
    menu = Menu:new{
        title = T(_("选择字体(共 %1 个)"), #items),
        item_table = items,
        width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * const.UI_WIDTH_WIDE),
        height = math.floor(Screen:getHeight() * 0.9),
        -- 兜底:Menu 自身的 close_callback 路径
        close_callback = function()
            if menu then
                UIManager:close(menu)
            end
        end,
    }
    UIManager:show(menu)
end

-- 字号:滑条+预设档位(替代 SpinWidget 数字键盘;上限 800,预设覆盖常用字号)
-- @param on_change 确认字号后的回调(文字插入弹窗用来刷新按钮标签)
function M:_pickFontSize(on_change)
    self:_showValuePicker{
        title = _("字号(无极调节)"),
        value = self.font_size,
        min = 8,
        max = 800,
        onchange = function(v)
            self.font_size = v
            self:_applySelectedTextStyle() -- 编辑文字中:实时改选中文字元素的字号
            self:_log("font_size ->", self.font_size)
            self:_updateStatus()
            if on_change then
                on_change()
            end
        end,
    }
end

-- 文件夹选择:Menu 列出 drawingboard/ 根目录与其下子文件夹(选中即关)
-- 注意:lfs.dir 返回 (iter, dir_obj) 两个值,迭代必须带上 dir_obj,
-- 否则子文件夹列表恒为空(只会弹"尚无子文件夹")
-- 选择保存文件夹:任意绝对路径浏览器(结构复刻 memobook 的列表弹窗)。
-- ButtonDialog 大按钮行:顶部控制行 [上一级][选择此目录][关闭],下方每行一个
-- 文件夹(带 "/",点按=进入)/PNG 文件(点按=提交目录+回调文件名)。进入文件夹
-- 关闭当前弹窗重建新弹窗(与 memobook 切列表同套路),可上溯到任意绝对路径。
-- 根目录=drawingboard 时 save_folder 存 "" 保持默认
-- file_ext(可选,默认 "%.png$")=列出的文件扩展名匹配(打开工程时传 "%.drawing$");
-- title_prefix(可选)=弹窗标题前缀(默认"选择保存文件夹: ")
function M:_pickSaveFolder(on_change, on_pick_file, file_ext, title_prefix)
    file_ext = file_ext or "%.png$"
    title_prefix = title_prefix or _("选择保存文件夹: ")
    local lfs = require("libs/libkoreader-lfs")
    local base = DataStorage:getDataDir() .. "/drawingboard"
    if lfs.attributes(base, "mode") ~= "directory" then
        pcall(lfs.mkdir, base)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog = nil
    local cur = base
    local function parentOf(p)
        if p == "/" then
            return nil
        end
        local head = p:match("^(.*)/[^/]*$")
        if not head or head == "" then
            return "/"
        end
        return head
    end
    local function titleOf(p)
        return (p == base) and "根目录" or p
    end
    local function commit(path)
        self.save_folder = (path == base) and "" or path
        self:_log("save_folder ->", self.save_folder)
        if on_change then on_change() end
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
    end
    local function commitFile(name)
        self.save_folder = (cur == base) and "" or cur
        self:_log("save_folder ->", self.save_folder, "pick file", name)
        if on_pick_file then
            on_pick_file(name:gsub(file_ext, "")) -- 去掉扩展名,保存流程自动补
        end
        if on_change then on_change() end
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
    end
    local function show()
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
        local rows = {}
        -- 顶部控制行(与文件浏览器同款):主目录一键回 drawingboard 根 / 上一级 / 选择此目录 / 关闭
        local parent = parentOf(cur)
        table.insert(rows, {
            {
                text = "主目录",
                callback = function()
                    if cur ~= base then
                        cur = base
                        show()
                    end
                end,
            },
            {
                text = "上一级",
                enabled = parent ~= nil,
                callback = function()
                    if parent then
                        cur = parent
                        show()
                    end
                end,
            },
            {
                text = "选择此目录",
                callback = function() commit(cur) end,
            },
            {
                text = "关闭",
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                        dialog = nil
                    end
                end,
            },
        })
        -- 内容行:子文件夹(进入)/已有 PNG 文件(选文件填名)
        local subs, files = {}, {}
        local ok, iter, dir_obj = pcall(lfs.dir, cur)
        if ok and iter then
            for name in iter, dir_obj do
                if name ~= "." and name ~= ".." then
                    local mode = lfs.attributes(cur .. "/" .. name, "mode")
                    if mode == "directory" then
                        table.insert(subs, name)
                    elseif name:lower():match(file_ext) then
                        table.insert(files, name)
                    end
                end
            end
        end
        table.sort(subs)
        table.sort(files)
        for _, name in ipairs(subs) do
            table.insert(rows, {
                {
                    text = name .. "/",
                    callback = function()
                        cur = cur .. "/" .. name
                        show()
                    end,
                },
            })
        end
        for _, name in ipairs(files) do
            table.insert(rows, {
                {
                    text = name,
                    callback = function() commitFile(name) end,
                },
            })
        end
        dialog = ButtonDialog:new{
            title = title_prefix .. titleOf(cur),
            buttons = rows,
            width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * const.UI_WIDTH_WIDE),
            shrink_unneeded_width = false,
        }
        UIManager:show(dialog)
    end
    show()
end

-- 关于弹窗:统一居中弹窗(components.showCenteredDialog,与笔触弹窗同构)。
-- 内容拆成独立单行 TextWidget —— 设备端多行 TextWidget 首帧可能整段不显示。
function M:_showAbout()
    local face = Font:getFace(self:_defaultFont(), 18)
    local function line(text)
        return TextWidget:new{ text = text, face = face }
    end
    local close_bt = ButtonTable:new{
        width = math.floor(Screen:getWidth() * const.UI_WIDTH_NARROW),
        buttons = {
            { { text = _("关闭"),
                callback = function()
                    if self._about_popup then
                        UIManager:close(self._about_popup, "full")
                        self._about_popup = nil
                    end
                end } },
        },
    }
    local content = VerticalGroup:new{
        align = "center",
        line(_("绘图板 drawingboard")),
        line(_("软件版本:") .. const.PLUGIN_VERSION),
        line(_("作者:") .. const.PLUGIN_AUTHOR),
        line("GitHub: https://github.com/eznas"),
        line(_("功能:自由画笔/图形/文字/填充/多图层")),
        line(_("保存路径:koreader/drawingboard/")),
        close_bt,
    }
    self._about_popup = components.showCenteredDialog{
        name = "DrawingAbout",
        title = _("关于"),
        content = content,
        log = function(...) self:_log(...) end,
    }
    return self._about_popup
end


return M
