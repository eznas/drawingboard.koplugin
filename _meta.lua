-- 插件元数据:名称/描述按系统语言双语——系统语言非中文显示英文,中文系统显示中文
-- (与 drawingpad/i18n.lua 的菜单规则一致;这里不 require 任何模块,保证 pluginmanager
--  任何加载时机都能用,直接读全局 G_reader_settings)
local function is_zh()
    local ok, lang = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("language") or nil
    end)
    return ok and type(lang) == "string" and lang:sub(1, 2) == "zh"
end

if is_zh() then
    return {
		name = "绘图板",
        fullname = "绘图板",
        description = "全屏绘图板:自由画笔(灰度/粗细可调)、直线、矩形、圆形、圆弧、文字插入(字体/字号/灰度)、橡皮、撤销/重做,可保存 PNG 到 koreader/drawingboard/。",
    }
end
return {
	name = "drawingboard",
    fullname = "Drawing Board",
    description = "Fullscreen drawing board: freehand brush (gray/width), lines, rectangles, ellipses, text (font/size/gray), eraser, undo/redo; saves PNG to koreader/drawingboard/.",
}
