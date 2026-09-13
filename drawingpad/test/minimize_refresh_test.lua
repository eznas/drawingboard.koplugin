-- 最小化/恢复刷新策略回归:不许整屏刷(墨水屏上"full" = 一次可见闪屏)
-- 背景:核心 _setMinimized 结尾是 UIManager:setDirty(self, "full") —— 每次点隐藏/
-- 恢复键整屏闪一下。真正变的像素只有底部一条(工具栏+状态栏 + 浮动"菜单"恢复键),
-- menus.lua 的 _toggleMinimize 吸收核心那发整屏刷、改发底部区域 "ui" 刷。
-- 本测试同时覆盖"有选中对象时切最小化"(取消选中那发区域刷必须照旧放行)。
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
        if type(mode) == "function" then
            -- 延迟形式(插件统一用法):让函数现在求值,才看得到真实的 mode/region
            local m, r = mode()
            calls[#calls + 1] = { mode = m, region = r, deferred = true }
        else
            calls[#calls + 1] = { mode = mode, region = region }
        end
    end
    return real_setDirty(uim, w, mode, region, dither)
end

local fails = {}
local function check(label, from)
    local n, full, nils = 0, 0, 0
    for i = from, #calls do
        n = n + 1
        if calls[i].mode == "full" then
            full = full + 1
        elseif calls[i].mode == "partial" and not calls[i].region then
            nils = nils + 1
        end
    end
    print(string.format("  %-26s 刷新 %d 次,full %d,无区域 partial %d",
                        label, n, full, nils))
    if full > 0 then
        fails[#fails + 1] = label .. ": " .. full .. " 次整屏 full 刷新(会闪屏)"
    end
    if nils > 0 then
        fails[#fails + 1] = label .. ": " .. nils .. " 次无区域 partial(整屏)刷新"
    end
    if n == 0 then
        fails[#fails + 1] = label .. ": 一次刷新都没有(底部那条没刷)"
    end
end

-- 1) 无选中:最小化 → 恢复
canvas:_setMinimized(true)          -- 先进入最小化(建初始态)
local m0 = #calls
canvas:_toggleMinimize()            -- 恢复
check("无选中:恢复", m0 + 1)
if canvas._minimized then
    fails[#fails + 1] = "恢复后 _minimized 仍为 true"
end
if canvas[1] ~= canvas.toolbar then
    fails[#fails + 1] = "恢复后 self[1] 不是工具栏"
end
m0 = #calls
canvas:_toggleMinimize()            -- 最小化
check("无选中:最小化", m0 + 1)
if not canvas._minimized then
    fails[#fails + 1] = "最小化后 _minimized 不为 true"
end
if canvas[1] ~= canvas.restore_btn then
    fails[#fails + 1] = "最小化后 self[1] 不是恢复键"
end
if canvas.header_h ~= 0 then
    fails[#fails + 1] = "最小化后 header_h 应为 0,实际 " .. tostring(canvas.header_h)
end

-- 2) 有选中对象:最小化(取消选中那发区域刷必须照旧发出去)
canvas:_toggleMinimize()            -- 先恢复
canvas:_setTool("brush")
canvas.width = 6
canvas:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 200, y = 200 } })
for i = 1, 10 do
    canvas:onPan(nil, { pos = { x = 200 + i * 8, y = 200 }, start_pos = { x = 200, y = 200 } })
end
canvas:onPanRelease(nil, { pos = { x = 280, y = 200 } })
canvas:_setTool("select")
canvas:onTap(nil, { pos = { x = 240, y = 200 } })
if not canvas._selected then
    fails[#fails + 1] = "选择工具没选中笔画(测试前置失败)"
end
m0 = #calls
canvas:_toggleMinimize()
check("有选中:最小化", m0 + 1)
if canvas._selected then
    fails[#fails + 1] = "最小化后选中未清除(选中框会残留)"
end

-- 3) 底部那条的刷新区域必须盖住工具栏/状态栏与恢复键所在位置
local screen_h = Device.screen:getHeight()
local band = nil
for i = #calls, 1, -1 do
    local r = calls[i].region
    if r and r.y and r.y + r.h >= screen_h - 1 and r.h <= canvas.toolbar_h + canvas.status_h then
        band = r
        break
    end
end
if not band then
    fails[#fails + 1] = "没有看到盖住屏幕底部一条的区域刷"
elseif band.y > screen_h - canvas.toolbar_h - canvas.status_h then
    fails[#fails + 1] = "底部区域太小,遮不住工具栏+状态栏:y=" .. band.y
end

if #fails > 0 then
    for _, f in ipairs(fails) do print("FAIL " .. f) end
    print("MINIMIZE_REFRESH_TEST_FAILED")
    os.exit(1)
end
print("PASS: minimize toggle refreshes only the bottom band")
