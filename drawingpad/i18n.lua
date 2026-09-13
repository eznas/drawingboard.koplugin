--[[--
drawingpad.i18n — 双语菜单(v62n,对齐 plugin_manager.koplugin 的实现方法)。
**英文为源语言**:代码里字符串一律英文,中文经 dict(英文→中文)查表。
语言解析 L.resolve(pref):menu_lang 设置("en"/"zh")优先;缺省 auto =
gettext.current_lang 以 zh 开头 → 中文,否则英文。必须在任何 UI 构造前调用
(drawing_canvas:init 里),t()/x() 运行时按当前语言取值。
- t(en, zh):成对直译(复合/动态串),zh 缺省回退 en。
- x(en):查字典 dict[en],查不到原样返回(单串、集中维护)。
--]]

local M = {
    lang = "en",
    -- 中文对照表(key = 英文原文;与 plugin_manager 的 LANG_TABLE 同套路)
    dict = {
        -- 分类面板条目(静态 label)
        ["Tool"] = "工具",
        ["Options"] = "属性设置",
        ["Layer"] = "图层",
        ["Menu"] = "功能",
        ["Brush"] = "画笔",
        ["Line"] = "直线",
        ["Text"] = "文字",
        ["Tip"] = "笔触",
        ["Eraser"] = "橡皮",
        ["Rect"] = "矩形",
        ["Select"] = "选择",
        ["Fill"] = "填充",
        ["Undo"] = "撤销",
        ["Redo"] = "重做",
        ["Clear"] = "清空",
        ["Open"] = "打开",
        ["Export"] = "输出",
        ["Save"] = "保存",
        ["About"] = "关于",
        ["Exit"] = "退出",
        ["Home"] = "主目录",
        ["Up"] = "上一级",
        ["Use this folder"] = "选择此目录",
        ["Close"] = "关闭",
        ["Cancel"] = "取消",
        ["Update"] = "更新",
        ["Insert"] = "插入",
        ["root folder"] = "根目录",
        -- 弹窗标题
        ["Gray"] = "灰度",
        ["Width"] = "粗细",
        ["Opacity"] = "透明度",
        ["Edit text"] = "修改文字",
        ["Insert text"] = "插入文字",
        ["Save PNG"] = "保存 PNG",
        ["Save project(editable)"] = "保存工程(可再编辑)",
        ["Open project: "] = "打开工程: ",
        ["Choose save folder: "] = "选择保存文件夹: ",
        ["Max gray(0%=white 100%=black)"] = "最大灰度(0%=白 100%=黑)",
        ["Min gray(0%=white 100%=black)"] = "最小灰度(0%=白 100%=黑)",
        ["Random levels(2-256)"] = "随机分级数(2-256)",
        ["Fixed gray(0%=white 100%=black)"] = "固定灰度(0%=白 100%=黑)",
        ["Thickest(px)"] = "最粗(px)",
        ["Thinnest(px)"] = "最细(px)",
        ["Fixed width(px)"] = "固定粗细(px)",
        ["Max opacity(100%=opaque)"] = "最浓(100%=不透明 0%=全透明)",
        ["Min opacity(100%=opaque)"] = "最淡(100%=不透明 0%=全透明)",
        ["Fixed opacity(100%=opaque)"] = "固定透明度(100%=不透明)",
        ["Selected gray(0%=white 100%=black)"] = "选中对象灰度(0%=白 100%=黑)",
        ["Selected width(px)"] = "选中对象粗细(px)",
        ["Selected opacity(100%=opaque)"] = "选中对象透明度(100%=不透明)",
        ["Size(free)"] = "字号(无极调节)",
        ["Layer opacity(100%=opaque)"] = "当前层透明度(100%=不透明)",
        ["Choose font (%1 total)"] = "选择字体(共 %1 个)",
        ["Font: "] = "字体: ",
        ["Size: "] = "字号: ",
        ["Edit text (font/size via buttons below)"] = "修改文字内容(字体/字号用下方按钮)",
        ["Enter text to insert"] = "输入要插入的文字(灰度用工具栏调整)",
        ["Filename(auto .png)"] = "文件名(自动补 .png)",
        ["Filename(auto .drawing)"] = "文件名(自动补 .drawing)",
        ["Folder: root"] = "文件夹: 根目录",
        ["Folder: "] = "文件夹: ",
        -- 设置弹窗按钮
        ["Max"] = "最大",
        ["Min"] = "最小",
        ["Thick"] = "最粗",
        ["Thin"] = "最细",
        ["Levels"] = "分级",
        ["Levels:%d"] = "分级:%d",
        ["Fixed"] = "固定",
        ["Fixed:%s"] = "固定:%s",
        ["Max:"] = "最大:",
        ["Min:"] = "最小:",
        -- 笔触菜单(const.TIPS 显示名)
        ["Ellipse"] = "圆形",
        ["Square"] = "方形",
        ["Triangle"] = "正三角",
        ["Inv tri"] = "倒三角",
        ["Diamond"] = "菱形",
        ["Slash"] = "斜线",
        ["Backslash"] = "反斜线",
        -- 状态栏缩写(const.TIP_NAMES)
        ["O"] = "圆",
        ["S"] = "方",
        ["T"] = "三",
        ["V"] = "倒",
        ["D"] = "菱",
        ["/"] = "斜",
        ["\\"] = "反",
        -- 状态栏图层(const.LAYER_NAMES)
        ["bottom"] = "下层",
        ["middle"] = "中层",
        ["top"] = "上层",
        -- Toast/确认
        ["Clear this layer? Cannot be undone."] = "确定清空当前图层?此操作不可撤销。",
        ["Canvas is empty, nothing to save."] = "画板是空的,没有内容可保存。",
        ["Filename cannot contain / or \\"] = "文件名不能含 / 或 \\ 字符",
        ["Saved:"] = "已保存:",
        ["Save failed, check folder permission:"] = "保存失败,请检查目录权限:",
        ["File not found:"] = "文件不存在:",
        ["Corrupt project file:"] = "工程文件损坏:",
        ["Opened:"] = "已打开:",
        ["Unsaved content, close anyway?"] = "画板有未保存内容,确定关闭?",
        ["This object has no line width."] = "该对象没有线条粗细。",
        ["This object has no line width"] = "该对象没有线条粗细",
        ["No usable font found (fonts folder)."] = "未找到可用字体(fonts 目录)。",
        ["Tip menu failed to open"] = "笔触菜单打开失败",
        ["Tip menu render failed"] = "笔触菜单渲染失败",
        -- 关于/语言切换
        ["drawingboard"] = "绘图板",
        ["Version:"] = "软件版本:",
        ["Author:"] = "作者:",
        ["Freehand/shapes/text/fill/layers"] = "功能:自由画笔/图形/文字/填充/多图层",
        ["Save to: koreader/drawingboard/"] = "保存路径:koreader/drawingboard/",
        ["Language: auto"] = "菜单语言:自动",
        ["Language: 中文"] = "菜单语言:中文",
        ["Language: English"] = "菜单语言:English",
        ["Menu language: English"] = "菜单语言已切换为英文,重开菜单生效",
        ["Menu language: Chinese"] = "菜单语言已切换为中文,重开菜单生效",
    },
}

-- 成对直译(复合/动态串):源语言英文
function M.t(en, zh)
    if M.lang == "zh" then
        return zh ~= nil and zh or en
    end
    return en
end

-- 查字典(单串)
function M.x(en)
    if M.lang == "zh" then
        local zh = M.dict[en]
        if zh ~= nil then
            return zh
        end
    end
    return en
end

-- 语言检测(对齐 plugin_manager.koplugin:模块加载期按 gettext.current_lang 判定)
--   local current_lang = gettext.current_lang or ""
--   local is_chinese = current_lang:match("^zh") and true or false
-- 差异:current_lang 为空/"C"(POSIX 未设置,常见于测试环境)时回退
-- G_reader_settings 的 language(用户真实选择),仍非 zh 才用英文
local function detect_is_chinese()
    local ok, current_lang = pcall(function()
        local gettext = require("gettext")
        return (gettext and gettext.current_lang) or ""
    end)
    if not ok or type(current_lang) ~= "string" then
        current_lang = ""
    end
    if current_lang ~= "" and current_lang ~= "C" then
        return current_lang:match("^zh") and true or false
    end
    local ok2, lang = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("language") or nil
    end)
    return ok2 and type(lang) == "string" and lang:match("^zh") and true or false
end

M.lang = detect_is_chinese() and "zh" or "en"

-- 解析语言:pref = "en"/"zh"(关于弹窗手动切换)覆盖;nil = 重新自动检测
function M.resolve(pref)
    if pref == "en" or pref == "zh" then
        M.lang = pref
        return M.lang
    end
    M.lang = detect_is_chinese() and "zh" or "en"
    return M.lang
end

return M
