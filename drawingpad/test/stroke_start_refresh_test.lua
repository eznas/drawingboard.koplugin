-- 起笔刷新策略回归:任何"画布刷新"都必须带区域
-- 背景:插件的 setDirty(partial, nil) 在 KOReader 里 = 整屏刷新(还会按次数升级成
-- full 闪刷),墨水屏上就是一次闪屏。历史 bug:快速起笔时(_renderStrokeTail 只画了
-- 起笔圆点、还没到能渲染线段,返回 nil)_stroke_region 仍是 nil,"起笔立即刷新"那发
-- 就变成整屏刷新 → 真机"快速起笔闪一下";慢起笔走 onHold(有 if rx0 守卫)不闪。
-- 本测试:模拟快/慢起笔,断言所有画布刷新的 mode=partial 且 region 非 nil。
-- 自定位插件根(模拟器 /home/m/koreader 与真机 /mnt/us/koreader 都能跑)
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local UIManager = require("ui/uimanager")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local canvas = DrawingCanvas:new{ on_close = function() end }
if not canvas.canvas_bb then canvas:_recreateCanvas() end

local calls = {}
local real_setDirty = UIManager.setDirty
UIManager.setDirty = function(uim, w, mode, region, dither)
    if w == canvas then
        calls[#calls + 1] = { mode = mode, region = region }
    end
    return real_setDirty(uim, w, mode, region, dither)
end

local function drain(from)
    local n, nils, empty = 0, 0, 0
    for i = from, #calls do
        n = n + 1
        local r = calls[i].region
        if calls[i].mode == "partial" and not r then
            nils = nils + 1
        elseif r and (r.w <= 0 or r.h <= 0) then
            empty = empty + 1
        end
    end
    return n, nils, empty
end

local function reset()
    canvas._stroke = nil
    canvas._stroke_pending = nil
    canvas._stroke_region = nil
    canvas._stroke_repaint_pending = false
    canvas._stroke_repaint_fn = nil
end

local fails = {}
local function case(label, fn)
    reset()
    local m0 = #calls
    fn()
    local n, nils, empty = drain(m0 + 1)
    print(string.format("  %-22s 刷新 %d 次,无区域 %d,空区域 %d", label, n, nils, empty))
    if nils > 0 then
        fails[#fails + 1] = label .. ": " .. nils .. " 次整屏(无区域)刷新"
    end
    if empty > 0 then
        fails[#fails + 1] = label .. ": " .. empty .. " 次空区域刷新"
    end
end

-- 快起笔 = 第 2 个 pan 就跳过阈值(手势检测调低 PAN_THRESHOLD 后真机很常见)
local function fast_start()
    canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
    canvas:onPan(nil, { pos = { x = 340, y = 300 }, start_pos = { x = 300, y = 300 } })
end

-- 慢起笔 = 按住不动先出 hold(0.5s),再拖动
local function slow_start()
    canvas:onHold(nil, { pos = { x = 300, y = 500 } })
    canvas:onPan(nil, { pos = { x = 340, y = 500 }, start_pos = { x = 300, y = 500 } })
end

for _, t in ipairs({ { "fill", "path", 1 }, { "brush", nil, 4 } }) do
    local tool, mode, w = t[1], t[2], t[3]
    canvas:_setTool(tool)
    if mode then canvas.fill_mode = mode end
    canvas.width = w
    case(tool .. " 快起笔", fast_start)
    case(tool .. " 慢起笔", slow_start)
end

-- 快起笔后连续画 + 收笔:整条链上只允许收笔那发"匀平残影"的全屏刷新(_penUpRefresh,
-- 每次抬笔一次是设计如此),起笔/中途一律必须带区域
canvas:_setTool("brush")
canvas.width = 4
reset()
local m0 = #calls
fast_start()
for i = 1, 20 do
    canvas:onPan(nil, { pos = { x = 340 + i * 6, y = 300 }, start_pos = { x = 300, y = 300 } })
end
canvas:onPanRelease(nil, { pos = { x = 460, y = 300 } })
local n, nils, empty = drain(m0 + 1)
print(string.format("  %-22s 刷新 %d 次,无区域 %d,空区域 %d", "整笔(快起笔+20点+收笔)", n, nils, empty))
if nils ~= 1 then
    fails[#fails + 1] = "整笔: 无区域刷新 " .. nils .. " 次(只该有收笔那一次匀平)"
elseif calls[#calls].region then
    fails[#fails + 1] = "整笔: 唯一那发无区域刷新不是收笔(说明是起笔/中途在整屏刷)"
end
if empty > 0 then fails[#fails + 1] = "整笔: " .. empty .. " 次空区域刷新" end
if #canvas.layers[2] ~= 1 then
    fails[#fails + 1] = "整笔未提交为 1 个元素(实际 " .. #canvas.layers[2] .. ")"
end

if #fails > 0 then
    for _, f in ipairs(fails) do print("FAIL " .. f) end
    print("START_FLASH_TEST_FAILED")
    os.exit(1)
end
print("PASS: stroke start refresh always regional")
