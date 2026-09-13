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

local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

local PASS, FAIL = 0, 0
local function check(cond, msg)
    if cond then
        PASS = PASS + 1
        print("PASS " .. msg)
    else
        FAIL = FAIL + 1
        print("FAIL " .. msg)
    end
end

-- ---- 几何工具 ----
local function polyBBox(pts)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p.x < x0 then x0 = p.x end
        if p.y < y0 then y0 = p.y end
        if p.x > x1 then x1 = p.x end
        if p.y > y1 then y1 = p.y end
    end
    return x0, y0, x1, y1
end

-- 偶奇规则点在多边形内
local function pointInPoly(x, y, pts)
    local inside = false
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[(i % n) + 1]
        if (a.y <= y and b.y > y) or (b.y <= y and a.y > y) then
            local xin = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
            if x < xin then inside = not inside end
        end
    end
    return inside
end

local function segDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = 0
    if l2 > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / l2
        t = math.max(0, math.min(1, t))
    end
    local qx, qy = ax + t * dx, ay + t * dy
    return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end

local function polyDist(x, y, pts)
    local d = math.huge
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[(i % n) + 1]
        d = math.min(d, segDist(x, y, a.x, a.y, b.x, b.y))
    end
    return d
end

-- 填充像素中离多边形边界 >tol 却在多边形外的数量(穿模量)
local function countOutside(el, pts, tol)
    local n = 0
    for _, sp in ipairs(el.spans) do
        for x = sp[2], sp[3] do
            if not pointInPoly(x, sp[1], pts) and polyDist(x, sp[1], pts) > tol then
                n = n + 1
            end
        end
    end
    return n
end

-- 行集致密(无空行)
local function spansDense(el)
    local ys = {}
    local ymin, ymax = math.huge, -math.huge
    for _, sp in ipairs(el.spans) do
        ys[sp[1]] = true
        if sp[1] < ymin then ymin = sp[1] end
        if sp[1] > ymax then ymax = sp[1] end
    end
    local n = 0
    for _ in pairs(ys) do n = n + 1 end
    return n > 0 and n == ymax - ymin + 1
end

-- ============ 1. 路径填充保存源顶点 ============
do
    local c = newCanvas()
    c:_setTool("fill")
    c:_toggleFillMode() -- path 模式
    c:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
    c:onPanRelease(nil, { pos = { x = 100, y = 300 } })
    local el = c.elements[1]
    check(el and el.kind == "fill", "path fill commits fill element")
    check(el.src_points and #el.src_points >= 3, "fill stores src_points, got "
        .. tostring(el.src_points and #el.src_points))
    check(#el.spans > 0, "fill has spans")
    check(countOutside(el, el.src_points, 1.5) == 0,
        "initial spans inside src polygon (outside>1.5px: "
        .. countOutside(el, el.src_points, 1.5) .. ")")

    -- ============ 2. 连续旋转 8×30° 不穿模 ============
    local x0, y0, x1, y1 = polyBBox(el.src_points)
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    local r0max = 0
    for _, p in ipairs(el.src_points) do
        r0max = math.max(r0max, math.sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2))
    end
    for i = 1, 8 do
        c:_rotateElement(el, math.pi / 6, cx, cy)
        c:_cacheBBox(el)
    end
    check(#el.spans > 0, "after 8 rotations spans non-empty")
    check(spansDense(el), "after 8 rotations rows dense")
    local outside = countOutside(el, el.src_points, 1.5)
    check(outside == 0, "after 8x30deg rotations fill hugs polygon (outside>1.5px: "
        .. outside .. ")")
    local rr = 0
    for _, sp in ipairs(el.spans) do
        for _, xx in ipairs({ sp[2], sp[3] }) do
            rr = math.max(rr, math.sqrt((xx - cx) ^ 2 + (sp[1] - cy) ^ 2))
        end
    end
    check(rr <= r0max + 1.5, "fill radius stable (" ..
        string.format("%.1f", rr) .. " <= " .. string.format("%.1f", r0max) .. "+1.5)")

    -- ============ 3. 缩放后仍贴合 ============
    local bx0, by0, bx1, by1 = polyBBox(el.src_points)
    local sb = { x0 = math.floor(bx0), y0 = math.floor(by0), x1 = math.ceil(bx1), y1 = math.ceil(by1) }
    local nb = { x0 = sb.x0, y0 = sb.y0, x1 = sb.x0 + (sb.x1 - sb.x0) * 1.5, y1 = sb.y0 + (sb.y1 - sb.y0) * 1.5 }
    c:_scaleElement(el, sb, nb)
    c:_cacheBBox(el)
    check(#el.spans > 0 and spansDense(el), "scale up 1.5x spans dense")
    check(countOutside(el, el.src_points, 1.5) == 0, "scale up 1.5x fill hugs polygon (outside: "
        .. countOutside(el, el.src_points, 1.5) .. ")")
    local nb2 = { x0 = nb.x0, y0 = nb.y0, x1 = nb.x0 + (nb.x1 - nb.x0) / 1.5, y1 = nb.y0 + (nb.y1 - nb.y0) / 1.5 }
    c:_scaleElement(el, nb, nb2)
    c:_cacheBBox(el)
    check(#el.spans > 0 and spansDense(el), "scale back down spans dense")
    check(countOutside(el, el.src_points, 1.5) == 0, "scale down fill hugs polygon (outside: "
        .. countOutside(el, el.src_points, 1.5) .. ")")

    -- ============ 4. 移动后旋转跟手 ============
    c:_moveElement(el, 50, 25)
    c:_cacheBBox(el)
    c:_rotateElement(el, math.pi / 4, (el._bbox.x0 + el._bbox.x1) / 2, (el._bbox.y0 + el._bbox.y1) / 2)
    c:_cacheBBox(el)
    local mx0, my0, mx1, my1 = polyBBox(el.src_points)
    check(math.abs(el._bbox.x0 - math.floor(mx0)) <= 2 and math.abs(el._bbox.y1 - math.ceil(my1)) <= 2,
        "rotate after move follows src_points")

    -- ============ 5. 快照/克隆深拷贝 ============
    local clone = c:_cloneElement(el)
    check(clone.src_points[1] ~= el.src_points[1], "clone deep-copies src_points")
    local snap = c:_cloneElement(el)
    c:_restoreGeom(el, snap)
    check(el.src_points[1] ~= snap.src_points[1]
        and el.src_points[1].x == snap.src_points[1].x
        and el.src_points[1].y == snap.src_points[1].y,
        "restore deep-copies src_points from snapshot (no aliasing)")
    local px, py = el.src_points[1].x, el.src_points[1].y
    c:_rotateElement(el, 0.3, 0, 0)
    check(snap.src_points[1].x == px and snap.src_points[1].y == py,
        "mutating el.src_points does not pollute snapshot")
end

-- ============ 6. tap 洪水填充(无 src_points)旧路径仍可用 ============
do
    local c = newCanvas()
    c:_setTool("fill") -- 默认 tap 模式
    c:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 200 } })
    c:onPanRelease(nil, { pos = { x = 150, y = 200 } })
    local el = c.elements[1]
    check(el and el.kind == "fill" and el.src_points == nil, "tap flood fill has no src_points")
    c:_rotateElement(el, math.pi / 6, 150, 200)
    c:_cacheBBox(el)
    check(#el.spans > 0 and spansDense(el), "legacy tap fill still rotates (spans dense)")
end

print(string.format("=== fill_transform_test: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
