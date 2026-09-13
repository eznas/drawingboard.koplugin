--[[--
工程文件(.drawing)保存/加载回归测试(v62d):
1. 保存含 2 层内容 + 显隐/透明度/当前层 的工程 → 新画布加载 → 元素/属性/像素逐项还原
2. 撤销栈被清空、私有字段(_bbox)重算
3. 损坏文件拒绝载入不崩

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/project_test.lua
--]]

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

local lfs = require("libs/libkoreader-lfs")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local PATH = "/tmp/dp_project_test.drawing"

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local function newCanvas()
    return DrawingCanvas:new{ on_close = function() end }
end

local function px(bb, x, y)
    local p = bb:getPixel(x, y)
    return p and p.a or -1
end

-- 画一笔(带中间点,防退化成墨点)
local function stroke(canvas, y)
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 80, y = y }, start_pos = { x = 80, y = y } })
    canvas:onPan(nil, { pos = { x = 200, y = y }, start_pos = { x = 80, y = y } })
    canvas:onPanRelease(nil, { pos = { x = 260, y = y } })
end

local passed = 0
local function section(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print(err)
        print("RESULT: " .. passed .. " passed, FAILED at above")
        os.exit(1)
    end
end

section("save/load roundtrip restores layers, attrs, pixels", function()
    pcall(os.remove, PATH)
    local canvas = newCanvas()
    -- 中层:半透明笔画
    canvas:_setTool("brush")
    canvas.alpha = 0.5
    stroke(canvas, 300)
    check(canvas.layers[2][1] ~= nil, "layer2 stroke committed")
    -- 下层:黑色笔画;上层留空并隐藏,层透明度调整
    canvas:_switchLayer(1)
    canvas.alpha = 1.0
    stroke(canvas, 320)
    canvas.layer_alpha[1] = 0.5
    canvas.layer_visible[3] = false
    canvas:_switchLayer(1) -- 当前层=下层保存

    local before = px(canvas.canvas_bb, 150, 300)

    check(canvas:_doSaveProject(PATH), "save ok")
    check(lfs.attributes(PATH, "mode") == "file", "file written")

    -- 另一块画布加载
    local c2 = newCanvas()
    stroke(c2, 500) -- 干扰内容,应被清掉
    c2:_loadProject(PATH)
    check(#c2.layers[2] == 1 and c2.layers[2][1].kind == "freehand", "layer2 restored")
    check(#c2.layers[1] == 1 and c2.layers[1][1].kind == "freehand", "layer1 restored")
    check(#c2.layers[3] == 0, "layer3 empty")
    check(math.abs((c2.layers[2][1].alpha or 1) - 0.5) < 0.001, "element alpha restored")
    check(c2.layer_visible[3] == false, "layer3 hidden restored")
    check(c2.layer_visible[2] == true, "layer2 visible restored")
    check(math.abs((c2.layer_alpha[1] or 1) - 0.5) < 0.001, "layer alpha restored")
    check(c2.active_layer == 1, "active layer restored")
    check(c2.elements == c2.layers[1], "elements rebound to active layer")
    check(#c2.undo == 0 and #c2.redo == 0, "undo/redo stacks reset")
    check(c2.layers[1][1]._bbox ~= nil, "bbox recomputed")
    -- 像素:半透明笔画在中层、下层 50% 层透明度,加载前后同坐标同灰度
    local after = px(c2.canvas_bb, 150, 300)
    check(math.abs(after - before) <= 1, "pixel roundtrip, before " .. before .. " after " .. after)
    -- 干扰内容被清掉(y=500 处无墨)
    check(px(c2.canvas_bb, 150, 500) >= 250, "stale content cleared")
    c2:onCloseWidget()
    canvas:onCloseWidget()
    os.remove(PATH)
end)

section("corrupt file rejected", function()
    local f = io.open(PATH, "w")
    f:write("this is not lua {{{")
    f:close()
    local canvas = newCanvas()
    local els_before = #canvas.elements
    local vis_before = { canvas.layer_visible[1], canvas.layer_visible[2], canvas.layer_visible[3] }
    canvas:_loadProject(PATH) -- 不应崩、不应改动状态
    check(#canvas.elements == els_before, "elements untouched on corrupt file")
    check(canvas.layer_visible[2] == vis_before[2], "visibility untouched")
    canvas:onCloseWidget()
    os.remove(PATH)
end)

print("RESULT: all " .. passed .. " sections passed")
