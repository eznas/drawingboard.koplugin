-- bench_bigsave.lua: 生成大幅面画布(30 笔 + 10 填充)保存, 供 gzip 基准
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
local UIManager = require("ui/uimanager")
UIManager.setDirty = function() end
local DrawingCanvas = require("drawingpad.drawing_canvas")

local canvas = DrawingCanvas:new{ on_close = function() end }
math.randomseed(3)
local npts = 0
for s = 1, 30 do
    canvas:_setTool("brush")
    local x, y = math.random(50, 900), math.random(50, 1300)
    canvas:onPan(nil, { pos = { x = x, y = y }, start_pos = { x = x, y = y } })
    for k = 1, 1500 do
        x = x + math.random(-8, 12); y = y + math.random(-6, 8)
        canvas:onPan(nil, { pos = { x = x, y = y }, start_pos = { x = x, y = y } })
    end
    canvas:onPanRelease(nil, { pos = { x = x, y = y } })
    npts = npts + 1500
end
for f = 1, 10 do
    canvas:_setTool("fill")
    canvas:_toggleFillMode()
    local cx, cy = math.random(200, 800), math.random(200, 1200)
    canvas:onPan(nil, { pos = { x = cx, y = cy }, start_pos = { x = cx, y = cy } })
    for a = 0, 40 do
        local ang = 2 * math.pi * a / 40
        canvas:onPan(nil, { pos = { x = cx + math.cos(ang) * 120, y = cy + math.sin(ang) * 120 },
                            start_pos = { x = cx, y = cy } })
    end
    canvas:onPanRelease(nil, { pos = { x = cx, y = cy } })
end
print("points:", npts, "elements:", #canvas.elements)
local ok = canvas:_doSaveProject("/tmp/big.drawing")
print("save:", ok and "ok" or "FAIL", lfs and "" or "")
local lfs = require("libs/libkoreader-lfs")
print("size:", lfs.attributes("/tmp/big.drawing", "size"))
