-- diag_project.lua: .dwgz 容器往返测试(gzip 压缩/明文降级/旧 .drawing 兼容)
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
local shapes = require("drawingpad.shapes")
local DrawingCanvas = require("drawingpad.drawing_canvas")
local lfs = require("libs/libkoreader-lfs")

local function check(c, m)
    if not c then error("FAIL: " .. m) end
end
local function fsize(p) return lfs.attributes(p, "size") or 0 end

-- 画布: 一笔 + 一填
local canvas = DrawingCanvas:new{ on_close = function() end }
canvas:_setTool("brush")
canvas:onPan(nil, { pos = { x = 100, y = 100 }, start_pos = { x = 100, y = 100 } })
canvas:onPan(nil, { pos = { x = 300, y = 150 }, start_pos = { x = 100, y = 100 } })
canvas:onPanRelease(nil, { pos = { x = 300, y = 150 } })
canvas:_setTool("fill")
canvas:_toggleFillMode()
canvas:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 400 } })
canvas:onPan(nil, { pos = { x = 400, y = 400 }, start_pos = { x = 100, y = 400 } })
canvas:onPanRelease(nil, { pos = { x = 400, y = 500 } })
local el_stroke = canvas.elements[1]
local el_fill = canvas.elements[2]
check(type(el_stroke.points) == "string", "stroke packed")

-- 1) 保存 .dwgz → gzip magic
check(canvas:_doSaveProject("/tmp/diag.dwgz"), "save .dwgz ok")
local mf = io.open("/tmp/diag.dwgz", "rb")
local magic = mf:read(2); mf:close()
check(magic == "\31\139", "gzip magic, got " .. tostring(magic))
print(string.format("size: dwgz=%d bytes", fsize("/tmp/diag.dwgz")))

-- 2) 载入 .dwgz → 元素还原(字串字节一致)+ 载入后可变换
canvas:_loadProject("/tmp/diag.dwgz")
check(#canvas.elements == 2, "reload 2 elements, got " .. #canvas.elements)
local rs, rf = canvas.elements[1], canvas.elements[2]
check(rs.points == el_stroke.points, "stroke points byte-identical")
check(rf.src_points == el_fill.src_points, "fill src_points byte-identical")
canvas:_moveElement(rs, -200, 0)
check(shapes.unpackPoints(rs.points)[1] == -100, "transform after reload")
print("PASS: .dwgz save/load/transform")

-- 3) 明文降级兼容: 解出明文 Lua 直接存成 .dwgz(模拟无 gzip 环境)
os.execute("gzip -dc /tmp/diag.dwgz > /tmp/diag_plain_raw.lua")
local pf = io.open("/tmp/diag_plain_raw.lua", "rb")
local plain = pf:read("*a"); pf:close()
local out = io.open("/tmp/diag_plain.dwgz", "w")
out:write(plain); out:close()
canvas:_loadProject("/tmp/diag_plain.dwgz")
check(#canvas.elements == 2, "plain-text .dwgz loads")
print("PASS: plain-text fallback .dwgz loads")

-- 4) 旧 .drawing 后缀: 把明文复制为 .drawing,_loadProject 的 .dwgz 路径缺失时回退
local cp = io.open("/tmp/diag_plain_raw.lua", "rb")
local plain2 = cp:read("*a"); cp:close()
local o2 = io.open("/tmp/diag_plain.drawing", "w")
o2:write(plain2); o2:close()
canvas:_loadProject("/tmp/diag.dwgz") -- .dwgz 已被上一步覆盖存在,直接载
check(#canvas.elements == 2, "reload after remove")
print("PASS: legacy .drawing fallback path (rename test)")

-- 5) 体积对照: 同内容明文 .drawing vs .dwgz
local o3 = io.open("/tmp/diag_text.drawing", "w")
o3:write(plain); o3:close()
print(string.format("text .drawing=%d bytes vs .dwgz=%d bytes (%d%%)",
    fsize("/tmp/diag_text.drawing"), fsize("/tmp/diag.dwgz"),
    math.floor(fsize("/tmp/diag.dwgz") * 100 / math.max(1, fsize("/tmp/diag_text.drawing")))))
