--[[--
drawingpad.i18n — 菜单文案中英双语(v62h)。
规则:设置项 menu_lang("en"/"zh")优先;缺省 auto = 系统(KOReader)语言非中文时
自动切英文菜单,仅系统语言是中文时显示中文。语言必须在任何 UI 构造前解析
(drawing_canvas:init 里 L.resolve),t()/x() 在运行时按当前语言取值。
- t(zh, en):成对直译(复合/动态串),en 缺省回退 zh。
- x(zh):查字典 dict[zh],查不到原样返回(单串、集中维护)。
--]]

local M = {
    lang = "zh",
    -- 英文对照表(key = 中文原文)
    dict = {
        -- 分类面板条目(静态 label)
        ["工具"] = "Tool",
        ["属性设置"] = "Options",
        ["图层"] = "Layer",
        ["功能"] = "Menu",
        ["画笔"] = "Brush",
        ["直线"] = "Line",
        ["文字"] = "Text",
        ["笔触"] = "Tip",
        ["撤销"] = "Undo",
        ["重做"] = "Redo",
        ["清空"] = "Clear",
        ["打开"] = "Open",
        ["输出"] = "Export",
        ["保存"] = "Save",
        ["关于"] = "About",
        ["退出"] = "Exit",
        -- 弹窗标题
        ["灰度"] = "Gray",
        ["粗细"] = "Width",
        ["透明度"] = "Opacity",
        ["修改文字"] = "Edit text",
        ["插入文字"] = "Insert text",
        ["保存 PNG"] = "Save PNG",
        ["保存工程(可再编辑)"] = "Save project(editable)",
        ["打开工程: "] = "Open project: ",
        ["选择保存文件夹: "] = "Choose save folder: ",
        ["最大灰度(0%=白 100%=黑)"] = "Max gray(0%=white 100%=black)",
        ["最小灰度(0%=白 100%=黑)"] = "Min gray(0%=white 100%=black)",
        ["随机分级数(2-256)"] = "Random levels(2-256)",
        ["固定灰度(0%=白 100%=黑)"] = "Fixed gray(0%=white 100%=black)",
        ["最粗(px)"] = "Thickest(px)",
        ["最细(px)"] = "Thinnest(px)",
        ["固定粗细(px)"] = "Fixed width(px)",
        ["最浓(100%=不透明 0%=全透明)"] = "Max opacity(100%=opaque)",
        ["最淡(100%=不透明 0%=全透明)"] = "Min opacity(100%=opaque)",
        ["固定透明度(100%=不透明)"] = "Fixed opacity(100%=opaque)",
        ["选中对象灰度(0%=白 100%=黑)"] = "Selected gray(0%=white 100%=black)",
        ["选中对象粗细(px)"] = "Selected width(px)",
        ["选中对象透明度(100%=不透明)"] = "Selected opacity(100%=opaque)",
        ["字号(无极调节)"] = "Size(free)",
        ["当前层透明度(100%=不透明)"] = "Layer opacity(100%=opaque)",
        ["选择字体(共 %1 个)"] = "Choose font (%1 total)",
        -- 设置弹窗按钮
        ["最大"] = "Max",
        ["最小"] = "Min",
        ["最粗"] = "Thick",
        ["最细"] = "Thin",
        ["最浓"] = "Max",
        ["最淡"] = "Min",
        ["分级"] = "Levels",
        ["固定"] = "Fixed",
        -- 笔触菜单(const.TIPS 显示名)
        ["圆形"] = "Ellipse",
        ["方形"] = "Square",
        ["正三角"] = "Triangle",
        ["倒三角"] = "Inv tri",
        ["菱形"] = "Diamond",
        ["斜线"] = "Slash",
        ["反斜线"] = "Backslash",
        -- 状态栏缩写(const.TIP_NAMES)
        ["圆"] = "O",
        ["方"] = "S",
        ["三"] = "T",
        ["倒"] = "V",
        ["菱"] = "D",
        ["斜"] = "/",
        ["反"] = "\\",
        -- 状态栏图层(const.LAYER_NAMES)
        ["下层"] = "bottom",
        ["中层"] = "middle",
        ["上层"] = "top",
        -- 通用按钮
        ["取消"] = "Cancel",
        ["关闭"] = "Close",
        ["更新"] = "Update",
        ["插入"] = "Insert",
        ["主目录"] = "Home",
        ["根目录"] = "root folder",
        ["上一级"] = "Up",
        ["选择此目录"] = "Use this folder",
        ["尚无子文件夹"] = "No subfolders",
        -- Toast/确认
        ["确定清空当前图层?此操作不可撤销。"] = "Clear this layer? Cannot be undone.",
        ["画板是空的,没有内容可保存。"] = "Canvas is empty, nothing to save.",
        ["文件名不能含 / 或 \\ 字符"] = "Filename cannot contain / or \\",
        ["已保存:"] = "Saved:",
        ["保存失败,请检查目录权限:"] = "Save failed, check folder permission:",
        ["文件不存在:"] = "File not found:",
        ["工程文件损坏:"] = "Corrupt project file:",
        ["已打开:"] = "Opened:",
        ["画板有未保存内容,确定关闭?"] = "Unsaved content, close anyway?",
        ["该对象没有线条粗细。"] = "This object has no line width.",
        ["该对象没有线条粗细"] = "This object has no line width",
        ["未找到可用字体(fonts 目录)。"] = "No usable font found (fonts folder).",
        ["文件名(自动补 .png)"] = "Filename(auto .png)",
        ["文件名(自动补 .drawing)"] = "Filename(auto .drawing)",
        ["笔触菜单打开失败"] = "Tip menu failed to open",
        ["笔触菜单渲染失败"] = "Tip menu render failed",
    },
}

-- 成对直译(复合/动态串)
function M.t(zh, en)
    if M.lang == "en" then
        return en ~= nil and en or zh
    end
    return zh
end

-- 查字典(单串)
function M.x(zh)
    if M.lang == "en" then
        local en = M.dict[zh]
        if en ~= nil then
            return en
        end
    end
    return zh
end

-- 解析语言:pref = "en"/"zh"/nil(auto)。auto 规则:系统语言非中文 → 英文菜单
-- (系统语言是中文 → 中文菜单;G_reader_settings 不可用/未设置=英文系统 → 英文)
function M.resolve(pref)
    if pref == "en" or pref == "zh" then
        M.lang = pref
        return M.lang
    end
    M.lang = "en"
    -- 直接读全局 G_reader_settings(KOReader/测试环境初始化时必建)
    local ok, syslang = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("language") or nil
    end)
    if ok and type(syslang) == "string" and syslang:sub(1, 2) == "zh" then
        M.lang = "zh"
    end
    return M.lang
end

return M
