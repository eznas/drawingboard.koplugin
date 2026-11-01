-- bench_fmt2.lua: 解码/解析耗时单独测(%q 载入 vs base64 解码), 输出安全拼接
package.path = "/home/m/koreader/plugins/drawingboard.koplugin/?.lua;" .. package.path
local bit = require("bit")
local band, rshift = bit.band, bit.rshift

-- 造 800KB 二进制(模拟打包字串)
local t0 = os.clock()
local parts = {}
for i = 1, 100000 do
    parts[#parts+1] = string.char(i % 256, (i*7) % 256, (i*13) % 256, (i*29) % 256)
end
local bin = table.concat(parts)
print(string.format("payload %d bytes", #bin))

-- 1) %q 转义 + loadstring 解析(现状的读回路径)
t0 = os.clock()
local q = string.format("%q", bin)
print(string.format("%%q escape: %.0f ms -> %d chars", (os.clock()-t0)*1000, #q))
t0 = os.clock()
local fn = loadstring("return " .. q)
print(string.format("%%q loadstring: %.0f ms", (os.clock()-t0)*1000))
local backq = fn and fn()
print(backq == bin and "%q roundtrip OK" or "%q ROUNDTRIP FAIL")

-- 2) base64 编码 + 解码(纯 Lua)
local B64, REV = {}, {}
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do
        B64[i-1] = chars:sub(i, i)
        REV[chars:sub(i, i)] = i - 1
    end
end
t0 = os.clock()
local out, n = {}, 0
for i = 1, #bin - 3, 3 * 4096 do
    local chunk = {}
    for j = i, math.min(i + 3 * 4096 - 1, #bin - 2), 3 do
        local a, b, c = bin:byte(j, j+2)
        local v = a * 65536 + b * 256 + c
        chunk[#chunk+1] = B64[rshift(v, 18)] .. B64[band(rshift(v, 12), 63)]
                       .. B64[band(rshift(v, 6), 63)] .. B64[band(v, 63)]
    end
    n = n + 1
    out[n] = table.concat(chunk)
end
local b64 = table.concat(out)
print(string.format("base64 encode: %.0f ms -> %d chars (%.2fx)", (os.clock()-t0)*1000, #b64, #b64/#bin))

t0 = os.clock()
b64 = b64:gsub("[^%w+/]", "")
local o2, m = {}, 0
for i = 1, #b64 - 3, 4 * 2048 do
    local chunk = {}
    for j = i, math.min(i + 4 * 2048 - 1, #b64 - 3), 4 do
        local a, b, c, d = REV[b64:sub(j,j)], REV[b64:sub(j+1,j+1)],
                           REV[b64:sub(j+2,j+2)], REV[b64:sub(j+3,j+3)]
        local v = a * 262144 + b * 4096 + c * 64 + d
        chunk[#chunk+1] = string.char(rshift(v, 16), band(rshift(v, 8), 255), band(v, 255))
    end
    m = m + 1
    o2[m] = table.concat(chunk)
end
local back = table.concat(o2)
print(string.format("base64 decode: %.0f ms, %s", (os.clock()-t0)*1000,
    back == bin and "roundtrip OK" or "ROUNDTRIP FAIL"))
