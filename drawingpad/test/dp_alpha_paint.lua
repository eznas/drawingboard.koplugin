-- 半透明功能 真实 paint 冒烟(坑 14c):新弹窗真实 paintTo 不崩 + 落盘 PNG 供目检。
-- 运行:cd 模拟器目录 && ./luajit .../test/../dp_alpha_paint.lua(临时脚本,不入库)
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Screen = Device.screen

local DrawingCanvas = require("drawingpad.drawing_canvas")
local canvas = DrawingCanvas:new{ on_close = function() end }

local outdir = "/home/m/dp_alpha_paint"
pcall(lfs.mkdir, outdir)

-- stub UIManager.show 捕获弹窗(不进事件循环),随后真实 paintTo(屏幕 BB)。
-- 注意 show 是冒号调用(UIManager:show(w)),第一个参数是 UIManager 自身
local captured = {}
UIManager.show = function(ui, w)
    captured[#captured + 1] = w
    return w
end

local function paintTop(name)
    local w = captured[#captured]
    if not w then
        print(name, "NO POPUP CAPTURED")
        return
    end
    local ok, err = pcall(function() w:paintTo(Screen.bb, 0, 0) end)
    print(name, ok and "paint OK" or ("PAINT CRASH: " .. tostring(err)))
    captured = {}
end

-- 画布上先画点东西:黑墨线 + 50% 透明实心矩形盖上去(目检混合效果)
canvas:_setTool("brush")
canvas.alpha = 1.0
canvas:onPan(nil, { pos = { x = 60, y = 200 }, start_pos = { x = 60, y = 200 } })
canvas:onPan(nil, { pos = { x = 460, y = 210 }, start_pos = { x = 60, y = 200 } })
canvas:onPanRelease(nil, { pos = { x = 470, y = 212 } })
canvas:_setTool("rect")
canvas.alpha = 0.5
canvas.rect_filled = true
canvas:onPan(nil, { pos = { x = 40, y = 160 }, start_pos = { x = 40, y = 160 } })
canvas:onPanRelease(nil, { pos = { x = 500, y = 420 } })
canvas:_updateStatus()
local ok, err = pcall(function() canvas:paintTo(Screen.bb, 0, 0) end)
print("canvas paintTo", ok and "OK" or ("CRASH: " .. tostring(err)))
canvas.canvas_bb:writePNG(outdir .. "/canvas_alpha.png")
print("canvas_alpha.png", (lfs.attributes(outdir .. "/canvas_alpha.png", "size") or 0) .. " bytes")

-- 1. 属性面板(透明度 与 笔触 并排)
canvas:_showCategoryMenu("prop")
paintTop("prop_panel")

-- 2. 透明度设置弹窗(最浓/最淡/分级/固定)
canvas:_pickAlpha()
paintTop("alpha_setting_dialog")

-- 3. 图层面板(含 当前层透明度 条目)
canvas:_showCategoryMenu("layer")
paintTop("layer_panel")

-- 4. 当前层透明度滑条弹窗
canvas:_pickLayerAlpha()
paintTop("layer_alpha_picker")

-- 5. 选中对象透明度滑条
canvas:_setTool("select")
canvas:onTap(nil, { pos = { x = 270, y = 290 } }) -- 选中透明矩形
print("selected", canvas._selected and canvas._selected.kind or "NONE")
canvas:_pickAlpha()
paintTop("element_alpha_picker")

print("DONE")
