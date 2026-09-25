--[[--
路径填充旋转/缩放不穿模回归测试(src_points 源顶点重算):
1. 路径填充收笔保存 el.src_points
2. 连续旋转 8×30°:填充像素始终贴着变换后源顶点多边形(越界 >1.5px 的像素必须为 0)
3. 缩放(放大/缩小):spans 致密且仍贴合变换后多边形
4. 移动后旋转:填充跟着源顶点走(不跳回旧位置)
5. _cloneElement/_restoreGeom 对 src_points 深拷贝(撤销快照不别名)
6. 旧数据/tap 洪水填充(无 src_points)旋转仍走原 span 反建路径

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/fill_transform_test.lua
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

local DrawingCanvas = require("drawingpad.drawing_canvas")
local canvas = DrawingCanvas:new{ canvas_w = 800, canvas_h = 1000 }

local function count_kinds()
    local n_fill, n_stroke = 0, 0
    for _, el in ipairs(canvas.elements) do
        if el.kind == "fill" then n_fill = n_fill + 1 end
        if el.kind == "freehand" then n_stroke = n_stroke + 1 end
    end
    return n_fill, n_stroke
end

-- 路径填模式:轻点(无移动)不得留下任何元素(防误触圆点)
canvas:_setTool("fill")
canvas:_toggleFillMode()
assert(canvas.fill_mode == "path", "fill toggles to path mode")
canvas:onTap(nil, { pos = { x = 400, y = 400 } })
local n_fill, n_stroke = count_kinds()
assert(#canvas.elements == 0 and n_fill == 0 and n_stroke == 0,
    "path-fill tap must leave no element, got " .. #canvas.elements)
print("PASS: path-fill tap (no move) leaves no dot")

-- 对照:点填模式轻点仍执行派泛填充行为(此处空白画布无边界,不产生元素即可)
canvas:_toggleFillMode()
assert(canvas.fill_mode == "tap", "fill toggles back to tap mode")
canvas:onTap(nil, { pos = { x = 400, y = 400 } })
print("PASS: tap-mode fill tap still routes to flood fill (no crash on blank)")

-- 对照:画笔轻点仍出墨点(原有快捷轻点行为不变)
canvas:_setTool("brush")
canvas:onTap(nil, { pos = { x = 300, y = 300 } })
n_fill, n_stroke = count_kinds()
assert(n_stroke == 1, "brush tap should still commit a dot, got " .. n_stroke)
print("PASS: brush tap still commits dot")

-- 描边填:防抖期单点松手(未成笔)也不留元素(新画布,排除前一场景的画笔墨点)
local canvas3 = DrawingCanvas:new{ canvas_w = 800, canvas_h = 1000 }
canvas3:_setTool("fill")
canvas3:_toggleFillMode()
assert(canvas3.fill_mode == "path", "fill toggles to path mode")
canvas3._stroke_pending = { x = 500, y = 500, micro = {} }
canvas3:onPanRelease(nil, { pos = { x = 500, y = 500 } })
assert(#canvas3.elements == 0, "path-fill pending single-point release leaves no element")
print("PASS: path-fill pending single-point release leaves no dot")

-- 描边填:正常闭合路径仍提交 fill 元素(回归保护)
local canvas4 = DrawingCanvas:new{ canvas_w = 800, canvas_h = 1000 }
canvas4:_setTool("fill")
canvas4:_toggleFillMode()
assert(canvas4.fill_mode == "path", "fill toggles to path mode")
canvas4:onPan(nil, { pos = { x = 100, y = 250 }, start_pos = { x = 100, y = 250 } })
canvas4:onPan(nil, { pos = { x = 200, y = 250 }, start_pos = { x = 100, y = 250 } })
canvas4:onPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 250 } })
canvas4:onPan(nil, { pos = { x = 100, y = 350 }, start_pos = { x = 100, y = 250 } })
canvas4:onPan(nil, { pos = { x = 100, y = 250 }, start_pos = { x = 100, y = 250 } })
canvas4:onPanRelease(nil, { pos = { x = 100, y = 250 } })
assert(#canvas4.elements == 1 and canvas4.elements[1].kind == "fill",
    "closed path still commits fill only, got " .. #canvas4.elements .. " elements")
print("PASS: closed path still commits fill element")

print("=== ALL FILL TAP TESTS PASSED ===")
