--[[--
绘图板插件(drawingboard.koplugin)— 打开全屏绘图板

入口:菜单 → 工具(Tools)→ 绘图板
画板本体在插件目录 plugins/drawingboard.koplugin/drawingpad/drawing_canvas.lua(DrawingCanvas),
本插件只负责注册菜单项,并携带调试日志路径(写入插件目录 drawingboard.log)。

功能:自由画笔(灰度/粗细可调)、直线、矩形、圆形、圆弧、文字插入(字体/字号/灰度)、
橡皮、撤销/重做、清空、保存 PNG(DataStorage:getDataDir()/drawingboard/)。
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local L = require("drawingpad.i18n")

local DrawingBoard = WidgetContainer:extend{
    name = "drawingboard",
    is_doc_only = false,
}

function DrawingBoard:init()
    self.ui.menu:registerToMainMenu(self)
end

function DrawingBoard:addToMainMenu(menu_items)
    menu_items.drawingboard = {
        -- 菜单名随界面语言(i18n 模块加载期已按 gettext.current_lang 判定);
        -- 副作用:require 会把 <koplugin>/drawingpad/?.lua 加进 package.path 之前
        -- 就能找到本模块——pluginloader 在 dofile(main.lua) 前已加 <koplugin>/?.lua,
        -- 但 drawingpad 是子目录,故这里用相对包名依赖 pluginloader 的路径注入
        text = L.t("Drawing Board", "绘图板"),
        sorting_hint = "more_tools",
        callback = function()
            local DrawingCanvas = require("drawingpad.drawing_canvas")
            local canvas = DrawingCanvas:new{
                on_close = function() end,
                -- 插件目录:调试日志 + 设置持久化(drawingpad_settings.lua,退出自动保存)
                plugin_path = self.path,
                log_path = self.path and (self.path .. "/drawingboard.log") or nil,
            }
            UIManager:show(canvas)
        end,
    }
end

return DrawingBoard
