-- diag_legacy.lua: 载入字串化之前保存的旧格式 .drawing(表格式 points/src_points)
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
package.path = __t_plugin .. "/?.lua;" .. package.path
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local shapes = require("drawingpad.shapes")
local DrawingCanvas = require("drawingpad.drawing_canvas")
local UIManager = require("ui/uimanager")
UIManager.setDirty = function() end

local canvas = DrawingCanvas:new{ on_close = function() end }
canvas:_loadProject("/tmp/legacy.drawing")
print("elements loaded:", #canvas.elements)
for i, el in ipairs(canvas.elements) do
    local pts = el.points and type(el.points) .. "(" .. #el.points .. ")" or "-"
    local src = el.src_points and type(el.src_points) .. "(" .. #el.src_points .. ")" or "-"
    print(string.format("#%d kind=%s points=%s src_points=%s spans=%s",
        i, el.kind, pts, src, el.spans and #el.spans or "-"))
end
-- 渲染不炸 + 变换(自动打包)
local ok, err = pcall(function() canvas:_renderAll() end)
print("renderAll:", ok and "ok" or ("FAIL " .. tostring(err)))
ok, err = pcall(function()
    for _, el in ipairs(canvas.elements) do
        canvas:_moveElement(el, -30, -30)
        canvas:_cacheBBox(el)
    end
end)
print("moveAll:", ok and "ok" or ("FAIL " .. tostring(err)))
if ok then
    local el1 = canvas.elements[1]
    if el1.kind == "freehand" and type(el1.points) == "string" then
        local p = shapes.unpackPoints(el1.points)
        print("after move first pt:", p[1], p[2])
    end
end
