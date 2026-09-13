-- 图层显隐的"旧核心"兼容 + 关闭路径容错
-- 背景:真机上把带乒乓缓存的核心文件回滚成了旧版(缺 _applyVisibilityToggle /
-- _invalidateVisCache),而 layers.lua / actions.lua 还在裸调用 → 长按图层整个失效
-- (被 wrapHandler 吞成一行日志)、每次关闭都记一条 error。两个调用点已改为能力探测,
-- 这里两组都测:有缓存(当前核心)与无缓存(模拟真机回滚后的核心)。
-- 自定位插件根(模拟器 /home/m/koreader 与真机 /mnt/us/koreader 都能跑)
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
local DrawingCanvas = require("drawingpad.drawing_canvas")
local Blitbuffer = require("ffi/blitbuffer")

local canvas = DrawingCanvas:new{ on_close = function() end }
if not canvas.canvas_bb then canvas:_recreateCanvas() end

local fails = {}
local function ck(cond, msg) if not cond then fails[#fails + 1] = msg end end

local function ink_at(x, y)
    return canvas.canvas_bb:getPixel(x, y).a
end

-- 画一个墨点(粗 24,便于采样)
canvas:_setTool("brush")
canvas.gray = 1.0
canvas.width = 24
pcall(function() canvas:_commitDot(200, 300) end)
ck(ink_at(200, 300) < 100, "前置:墨点没画上(值 " .. ink_at(200, 300) .. ")")

-- ① 有乒乓缓存的核心:显隐两次应往返
canvas.layer_visible[canvas.active_layer] = true
canvas:_toggleLayerVisible()
local hidden = ink_at(200, 300)
ck(canvas.layer_visible[canvas.active_layer] == false, "① 标记没翻转")
ck(hidden > 200, "① 隐藏后画布仍有墨迹(值 " .. hidden .. ")")
canvas:_toggleLayerVisible()
ck(canvas.layer_visible[canvas.active_layer] == true, "① 恢复标记没翻转")
ck(ink_at(200, 300) < 100, "① 恢复后墨迹没回来(值 " .. ink_at(200, 300) .. ")")
print("  ① 有缓存核心:隐藏 " .. hidden .. " → 恢复 " .. ink_at(200, 300))

-- ② 模拟真机回滚后的旧核心:两个方法都不存在,显隐仍必须生效且不报错
canvas._applyVisibilityToggle = nil
canvas._invalidateVisCache = nil
local ok, err = pcall(function() canvas:_toggleLayerVisible() end)
ck(ok, "② 旧核心下 _toggleLayerVisible 报错: " .. tostring(err))
ck(canvas.layer_visible[canvas.active_layer] == false, "② 标记没翻转")
ck(ink_at(200, 300) > 200, "② 旧核心下隐藏没生效(值 " .. ink_at(200, 300) .. ")")
ok, err = pcall(function() canvas:_toggleLayerVisibleOf(1) end)
ck(ok, "② 旧核心下 _toggleLayerVisibleOf 报错: " .. tostring(err))
local w1 = canvas.layer_visible[1]
canvas:_toggleLayerVisibleOf(1)
ck(canvas.layer_visible[1] ~= w1, "② 图层面板切换别的层没生效")
print("  ② 旧核心(无乒乓缓存):显隐仍生效")

-- ③ 关闭路径:没有 _invalidateVisCache 也不该再报错
ok, err = pcall(canvas.onCloseWidget, canvas)
ck(ok, "③ 旧核心下 onCloseWidget 报错: " .. tostring(err))
print("  ③ 旧核心下关闭不动用缺失方法")

if #fails > 0 then
    for _, f in ipairs(fails) do print("FAIL " .. f) end
    print("LAYER_VISIBLE_FALLBACK_FAILED")
    os.exit(1)
end
print("PASS: layer visibility works with and without ping-pong cache")
