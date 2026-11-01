-- diag_size.lua: 新旧序列化体积对比(载入同一画布, %.4f 版 vs tostring 版)
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
local DrawingCanvas = require("drawingpad.drawing_canvas")
local UIManager = require("ui/uimanager")
UIManager.setDirty = function() end
local lfs = require("libs/libkoreader-lfs")

local canvas = DrawingCanvas:new{ on_close = function() end }
canvas:_loadProject("/tmp/legacy.drawing")
local n = 0
for li = 1, 3 do n = n + #canvas.layers[li] end
print("elements:", n)
local ok = canvas:_doSaveProject("/tmp/resaved.drawing")
print("save:", ok and "ok" or "FAIL")
local function sz(p) return lfs.attributes(p, "size") or 0 end
print(string.format("old(%%.4f) = %d bytes, new(tostring) = %d bytes (%.0f%%)",
    sz("/tmp/legacy.drawing"), sz("/tmp/resaved.drawing"),
    100.0 * sz("/tmp/resaved.drawing") / math.max(1, sz("/tmp/legacy.drawing"))))
-- 再载入验证无损
canvas:_loadProject("/tmp/resaved.drawing")
local m = 0
for li = 1, 3 do m = m + #canvas.layers[li] end
print("reload elements:", m, m == n and "OK" or "MISMATCH")
