--[[--
显隐乒乓缓存回归测试(v62d 模块侧实现,不改核心):
1. 显隐切换后缓存存在且掩码正确
2. 再次切换 = 整幅交换(canvas_bb 对象变化、缓存掩码翻回),零重放路径
3. 画布内容变动(提交墨点)后缓存被作废
4. 交替显隐第三次切换直接命中交换(canvas_bb 指针与第一次切换后一致)

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/cache_toggle_test.lua
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

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local function newCanvas()
    return DrawingCanvas:new{ on_close = function() end }
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

-- 画一笔(带中间点,防退化成墨点)
local function stroke(canvas, y)
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 80, y = y }, start_pos = { x = 80, y = y } })
    canvas:onPan(nil, { pos = { x = 200, y = y }, start_pos = { x = 80, y = y } })
    canvas:onPanRelease(nil, { pos = { x = 260, y = y } })
end

section("cache created on first toggle, swapped on second", function()
    local canvas = newCanvas()
    stroke(canvas, 300)
    check(canvas._vis_cache == nil, "no cache before toggle")
    canvas:_toggleLayerVisible() -- 隐藏当前层(中层)
    check(canvas.layer_visible[2] == false, "layer hidden")
    check(canvas._vis_cache ~= nil, "cache created")
    check(canvas._vis_cache.mask == 7, "cache holds pre-toggle mask 7, got " .. tostring(canvas._vis_cache.mask))
    check(canvas._canvas_mask == 5, "current mask 5, got " .. tostring(canvas._canvas_mask))
    local bb1 = canvas.canvas_bb
    canvas:_toggleLayerVisible() -- 再显示:应整幅交换
    check(canvas.layer_visible[2] == true, "layer shown")
    check(canvas.canvas_bb ~= bb1, "canvas_bb swapped (zero-replay path)")
    check(canvas._vis_cache.mask == 5, "cache mask flipped to 5, got " .. tostring(canvas._vis_cache.mask))
    canvas:_invalidateVisCache()
    canvas:onCloseWidget()
end)

section("mutation invalidates cache", function()
    local canvas = newCanvas()
    stroke(canvas, 300)
    canvas:_toggleLayerVisible()
    check(canvas._vis_cache ~= nil, "cache created")
    canvas:_toggleLayerVisible()
    check(canvas._vis_cache ~= nil, "cache alive after swap")
    -- 内容变动(墨点提交走 _commitRegionReplay 跳过分支的作废)
    canvas:_commitDot(150, 400)
    check(canvas._vis_cache == nil, "cache invalidated by content change")
    canvas:_toggleLayerVisible()
    check(canvas._vis_cache ~= nil, "cache rebuilt on next toggle")
    canvas:_invalidateVisCache()
    canvas:onCloseWidget()
end)

section("redraw ops invalidate cache", function()
    local canvas = newCanvas()
    stroke(canvas, 300)
    canvas:_toggleLayerVisible()
    check(canvas._vis_cache ~= nil, "cache created")
    canvas:_redrawRegion({ x = 60, y = 280, w = 60, h = 40 })
    check(canvas._vis_cache == nil, "cache invalidated by _redrawRegion")
    canvas:_toggleLayerVisible()
    canvas:_renderAll()
    check(canvas._vis_cache == nil, "cache invalidated by _renderAll")
    canvas:onCloseWidget()
end)

print("RESULT: all " .. passed .. " sections passed")
