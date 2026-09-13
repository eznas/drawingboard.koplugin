--[[--
图层遮挡回归测试:低层(1)提交新墨迹(笔画/墨点/图形/文字)后,
高层(3)已有墨迹必须仍盖住它(像素=高层灰度);修复前低层新墨迹
直接画进 canvas_bb 恒在最上,会错误压住高层。

运行:
    cd koreader-emulator-x86_64-linux-gnu-debug/koreader && ./luajit \
      /home/m/koreader/plugins/drawingboard.koplugin/drawingpad/test/layer_zorder_test.lua
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

local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local function px(canvas, x, y)
    return canvas.canvas_bb:getPixel(x, y).a
end

-- 断言矩形区域内全部像素接近期望灰度(容差)
local function bandIs(canvas, x0, y0, x1, y1, want, tol, msg)
    for y = y0, y1 do
        for x = x0, x1 do
            local a = px(canvas, x, y)
            if math.abs(a - want) > tol then
                error(string.format("FAIL: %s at (%d,%d) a=%d want~%d", msg, x, y, a, want))
            end
        end
    end
end

-- ============ 1. 笔画:高层(3)黑横线,低层(1)灰竖线穿越 → 交点仍是黑 ============
do
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.width = 10

    -- 高层画黑横线:x 100..200 @ y=200,宽 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })
    check(#canvas.layers[3] == 1, "layer3 has 1 stroke")
    check(px(canvas, 150, 200) < 20, "top stroke ink black before conflict")

    -- 切低层画灰竖线:x=150, y 150..250,宽 10,灰 0.5
    canvas:_switchLayer(1)
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 150, y = 150 }, start_pos = { x = 150, y = 150 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 150 } })
    canvas:onPanRelease(nil, { pos = { x = 150, y = 250 } })
    check(#canvas.layers[1] == 1, "layer1 has 1 stroke")

    -- 交点区域必须仍是高层黑(修复前低层灰竖线画在最上 → a≈128)
    bandIs(canvas, 145, 197, 155, 203, 0, 40, "stroke crossing occluded by top layer")
    -- 低层竖线在冲突区外的部分正常显示(灰 ≈128)
    check(math.abs(px(canvas, 150, 160) - 128) < 60, "lower stroke visible outside overlap")
    canvas:onCloseWidget()
    print("PASS: stroke commit respects layer order")
end

-- ============ 2. 墨点:低层点在高层黑线上 → 保持黑 ============
do
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.width = 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })

    canvas:_switchLayer(1)
    canvas.gray = 0.5
    canvas:_commitDot(150, 200)
    check(#canvas.layers[1] == 1, "dot committed on layer1")
    bandIs(canvas, 147, 198, 153, 202, 0, 40, "dot under top stroke")
    canvas:onCloseWidget()
    print("PASS: dot commit respects layer order")
end

-- ============ 3. 图形:低层灰矩形边穿过高层黑竖线 → 交点仍是黑 ============
do
    local canvas = newCanvas()
    -- 高层黑竖线 x=150, y 150..250
    canvas:_setTool("brush")
    canvas.width = 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 150, y = 150 }, start_pos = { x = 150, y = 150 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 150 } })
    canvas:onPanRelease(nil, { pos = { x = 150, y = 250 } })

    -- 低层灰空心矩形 (120,180)-(180,220),宽 6:上边 y=180 穿过竖线
    canvas:_switchLayer(1)
    canvas:_setTool("rect")
    canvas.width = 10
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 120, y = 180 }, start_pos = { x = 120, y = 180 } })
    canvas:onPanRelease(nil, { pos = { x = 180, y = 220 } })
    check(#canvas.layers[1] == 1, "rect committed on layer1")
    check(px(canvas, 150, 180) < 20, "rect edge crossing stays occluded by top stroke")
    -- 矩形边在无冲突处正常显示
    check(math.abs(px(canvas, 120, 200) - 128) < 70, "rect edge visible outside overlap")
    canvas:onCloseWidget()
    print("PASS: shape commit respects layer order")
end

-- ============ 4. 文字:低层文字与高层黑带重叠 → 重叠带内不许出现文字灰 ============
do
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.width = 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })

    canvas:_switchLayer(1)
    canvas:_setTool("text")
    canvas.gray = 0.5
    canvas:_commitText(110, 185, "WWWW")
    check(#canvas.layers[1] == 1, "text committed on layer1")
    -- 高层黑线带 (x105..195, y197..203) 内不得被文字灰墨覆盖
    bandIs(canvas, 105, 197, 195, 203, 0, 40, "text under top stroke band")
    canvas:onCloseWidget()
    print("PASS: text commit respects layer order")
end

-- ============ 5. 最高层作画不受影响:层3 新笔画正常盖住层1 ============
do
    local canvas = newCanvas()
    canvas:_switchLayer(1)
    canvas:_setTool("brush")
    canvas.width = 10
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })

    canvas:_switchLayer(3)
    canvas.gray = 1.0
    canvas:onPan(nil, { pos = { x = 150, y = 150 }, start_pos = { x = 150, y = 150 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 150 } })
    canvas:onPanRelease(nil, { pos = { x = 150, y = 250 } })
    check(px(canvas, 150, 200) < 20, "top-layer stroke paints over lower ink")
    canvas:onCloseWidget()
    print("PASS: top-layer painting unaffected")
end

print("ALL LAYER Z-ORDER TESTS PASSED")
