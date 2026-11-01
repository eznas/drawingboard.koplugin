-- bench_fmt.lua: .writing 编码方案性能对比(载荷 = 100k 点 float32 打包 ≈ 800KB)
package.path = "/home/m/koreader/plugins/drawingboard.koplugin/?.lua;" .. package.path
local ffi = require("ffi")
local bit = require("bit")
local band, rshift = bit.band, bit.rshift
local shapes = require("drawingpad.shapes")

-- 造载荷: 10 万点
local pts = {}
for i = 1, 100000 do pts[2*i-1], pts[2*i] = (i * 7) % 1088, (i * 13) % 1440 end
collectgarbage("collect")
local t0 = os.clock()
local bin = shapes.packPoints(pts)
local t_pack = os.clock() - t0
print(string.format("payload: %d bytes (%.2f MB), pack=%.0f ms", #bin, #bin/1048576, t_pack*1000))

-- 1) 现状: %q 转义
t0 = os.clock()
local q = string.format("%q", bin)
print(string.format("%%q     : %.0f ms -> %d bytes (%.2fx)", (os.clock()-t0)*1000, #q, #q/#bin))

-- 2) base64(纯 Lua LUT 实现, 与将写入插件的一致)
local B64 = {}
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do B64[i-1] = chars:sub(i, i) end
end
local function b64encode(data)
    local out, n = {}, 0
    local len = #data
    for i = 1, len - len % 3, 3 do
        local a, b, c = data:byte(i, i+2)
        local n24 = a * 65536 + b * 256 + c
        out[#out+1] = B64[band(rshift(n24, 18), 63)] .. B64[band(rshift(n24, 12), 63)]
                   .. B64[band(rshift(n24, 6), 63)] .. B64[band(n24, 63)]
    end
    local rem = len % 3
    if rem == 1 then
        local a = data:byte(len)
        local n24 = a * 65536
        out[#out+1] = B64[band(rshift(n24, 18), 63)] .. B64[band(rshift(n24, 12), 63)] .. "=="
    elseif rem == 2 then
        local a, b = data:byte(len-1, len)
        local n24 = a * 65536 + b * 256
        out[#out+1] = B64[band(rshift(n24, 18), 63)] .. B64[band(rshift(n24, 12), 63)]
                   .. B64[band(rshift(n24, 6), 63)] .. "="
    end
    return table.concat(out)
end
t0 = os.clock()
local b64 = b64encode(bin)
local t_enc = os.clock() - t0
print(string.format("base64 : %.0f ms (encode) -> %d bytes (%.2fx)", t_enc*1000, #b64, #b64/#bin))
-- 解码耗时
t0 = os.clock()
local rev = {}
for i = 1, 64 do rev[B64[i-1]] = i - 1 end
local function b64decode(data)
    data = data:gsub("=", "")
    local out = {}
    local n = 0
    for i = 1, #data, 4 do
        local a, b, c, d = rev[data:sub(i,i)], rev[data:sub(i+1,i+1)],
                           rev[data:sub(i+2,i+2)], rev[data:sub(i+3,i+3)]
        local n24 = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        n = n + 1; out[n] = band(rshift(n24, 16), 255)
        if c then n = n + 1; out[n] = band(rshift(n24, 8), 255) end
        if d then n = n + 1; out[n] = band(n24, 255) end
    end
    return string.char(unpack(out))
end
local back = b64decode(b64)
print(string.format("base64 : %.0f ms (decode), %s", (os.clock()-t0)*1000,
    back == bin and "roundtrip OK" or "ROUNDTRIP FAIL"))

-- 3) %q 解析回载(loadstring)耗时
t0 = os.clock()
local backq = loadstring("return " .. q)()
print(string.format("%%q     : %.0f ms (loadstring parse), %s", (os.clock()-t0)*1000,
    backq == bin and "roundtrip OK" or "ROUNDTRIP FAIL"))
