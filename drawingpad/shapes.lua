--[[--
绘图板纯渲染原语(shapes)。

只依赖 BlitBuffer 的 paintRect/getWidth/getHeight,不依赖 UI,可独立 headless 测试。
画线 = 相邻点插值 + 逐点画笔触形状(见 shapes.tip),不依赖 BlitBuffer 是否有 drawLine。

元素结构(drawElement 分派用):
- freehand / eraser: { kind, points = {{x,y},...}, width, tip? }
- line:            { kind, x0, y0, x1, y1, width, tip? }
- rect:            { kind, x0, y0, x1, y1, width, filled? }
- circle:          { kind, cx, cy, r, width, filled? }

filled = true 时实心(填充 + 描边);空心(默认)只描边。
颜色由调用方传入(对 BB8 画布即 Blitbuffer.gray(level) 的 Color8)。
tip(笔触形状,仅画笔/直线用):circle/square/triangle/triangle_inv/diamond/slash/backslash,
缺省/其他值 = circle,向后兼容。
--]]

local shapes = {}

-- 画一个 width 见方的点(裁剪到画布内,负坐标/越界安全)
function shapes.dot(bb, x, y, width, color)
    local half = math.floor(width / 2)
    local px = math.floor(x) - half
    local py = math.floor(y) - half
    local bw, bh = bb:getWidth(), bb:getHeight()
    if px + width <= 0 or py + width <= 0 or px >= bw or py >= bh then
        return -- 完全在画布外
    end
    local x0 = math.max(px, 0)
    local y0 = math.max(py, 0)
    local x1 = math.min(px + width, bw)
    local y1 = math.min(py + width, bh)
    bb:paintRect(x0, y0, x1 - x0, y1 - y0, color)
end

-- 圆头笔刷单元:半径 width/2 的实心圆(圆形笔触,粗线采样点,消除斜线/圆的锯齿)
function shapes.roundDot(bb, x, y, width, color)
    shapes.fillCircle(bb, x, y, math.max(0.5, width / 2), color)
end

-- 填充正三角(尖朝上)或倒三角(尖朝下):逐行扫描,半宽从顶点 0 线性到中心 w/2
local function fillTriangle(bb, cx, cy, w, color, inverted)
    w = math.max(2, w)
    local half = w / 2
    local y_top = cy - half
    local y0 = math.max(0, math.floor(y_top))
    local y1 = math.min(bb:getHeight() - 1, math.ceil(cy + half))
    for y = y0, y1 do
        local t = (y - y_top) / w
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local halfw = inverted and (half * (1 - t)) or (half * t)
        local x0 = math.max(0, math.ceil(cx - halfw))
        local x1 = math.min(bb:getWidth() - 1, math.floor(cx + halfw))
        if x1 >= x0 then
            bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
        end
    end
end

-- 填充菱形(旋转 45° 的正方形):逐行扫描,半宽从顶点 0 线性到中心 w/2 再收拢
local function fillDiamond(bb, cx, cy, w, color)
    local half = w / 2
    local y0 = math.max(0, math.floor(cy - half))
    local y1 = math.min(bb:getHeight() - 1, math.ceil(cy + half))
    for y = y0, y1 do
        local halfw = half - math.abs(y - cy)
        if halfw >= 0 then
            local x0 = math.max(0, math.ceil(cx - halfw))
            local x1 = math.min(bb:getWidth() - 1, math.floor(cx + halfw))
            if x1 >= x0 then
                bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
            end
        end
    end
end

-- 斜线笔触:45° 粗线段(反斜线镜像);斜线与反斜线用细一号的圆头粗线
local function fillSlash(bb, cx, cy, w, color, backslash)
    local off = w / 2
    local t = math.max(2, math.floor(w / 3))
    if backslash then
        shapes.thickLine(bb, cx - off, cy - off, cx + off, cy + off, t, color)
    else
        shapes.thickLine(bb, cx - off, cy + off, cx + off, cy - off, t, color)
    end
end

-- 笔触形状分派:在 (x,y) 处画一个宽为 width 的笔触(全部裁剪到画布内)
function shapes.tip(bb, x, y, width, color, tip)
    if tip == "square" then
        shapes.dot(bb, x, y, width, color)
    elseif tip == "triangle" then
        fillTriangle(bb, x, y, width, color, false)
    elseif tip == "triangle_inv" then
        fillTriangle(bb, x, y, width, color, true)
    elseif tip == "diamond" then
        fillDiamond(bb, x, y, width, color)
    elseif tip == "slash" then
        fillSlash(bb, x, y, width, color, false)
    elseif tip == "backslash" then
        fillSlash(bb, x, y, width, color, true)
    else
        shapes.roundDot(bb, x, y, width, color) -- circle 默认
    end
end

-- 粗线段扫描线填充:条带(沿线段两侧偏移 width/2 的两条平行边)+ 两端圆盖,
-- 逐行求 x 区间合并后填充。相比"采样圆点"拼线,边缘平滑——无圆点采样造成的
-- 边界首行虚线/扇形锯齿(粗线正方形"锯齿严重"的根因)。斜线/圆/笔画同样受益。
-- 端点退化(长度≈0)时画实心圆
function shapes.thickLineFill(bb, x0, y0, x1, y1, width, color)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then
        shapes.fillCircle(bb, x0, y0, math.max(0.5, width / 2), color)
        return
    end
    local r = math.max(0.5, width / 2)
    local ux, uy = dx / len, dy / len -- 单位方向
    local nx, ny = -uy, ux -- 单位法向
    local rnx, rny = nx * r, ny * r
    local y_min = math.max(0, math.floor(math.min(y0, y1) - r))
    local y_max = math.min(bb:getHeight() - 1, math.ceil(math.max(y0, y1) + r))
    local bw = bb:getWidth() - 1
    for y = y_min, y_max do
        local x_lo, x_hi = math.huge, -math.huge
        -- 端盖圆盘(起点/终点)
        local h0 = r * r - (y - y0) * (y - y0)
        if h0 >= 0 then
            local h = math.sqrt(h0)
            if x0 - h < x_lo then x_lo = x0 - h end
            if x0 + h > x_hi then x_hi = x0 + h end
        end
        local h1 = r * r - (y - y1) * (y - y1)
        if h1 >= 0 then
            local h = math.sqrt(h1)
            if x1 - h < x_lo then x_lo = x1 - h end
            if x1 + h > x_hi then x_hi = x1 + h end
        end
        if dy ~= 0 then
            -- 中间条带 = 平行四边形 [A+nr, B+nr, B-nr, A-nr],覆盖线段全长(含两端斜切区)。
            -- 逐行求扫描线与四边的交点区间——只填"两偏移边都横跨"的中段会导致线段
            -- 两端附近的条带主体缺失,斜角矩形角上露 V 形豁口(旋转后"怪异"根因)
            local x_lo2, x_hi2 = math.huge, -math.huge
            local function addEdge(px, py, qx, qy)
                if py == qy then
                    return -- 水平边不与扫描线相交于单点,跳过
                end
                local ylo, yhi = math.min(py, qy), math.max(py, qy)
                if y >= ylo - 0.001 and y <= yhi + 0.001 then
                    local x = px + (y - py) * (qx - px) / (qy - py)
                    if x < x_lo2 then x_lo2 = x end
                    if x > x_hi2 then x_hi2 = x end
                end
            end
            -- 四边:上偏移边 A+nr→B+nr,端边 B+nr→B-nr,下偏移边 B-nr→A-nr,端边 A-nr→A+nr
            addEdge(x0 + rnx, y0 + rny, x1 + rnx, y1 + rny)
            addEdge(x1 + rnx, y1 + rny, x1 - rnx, y1 - rny)
            addEdge(x1 - rnx, y1 - rny, x0 - rnx, y0 - rny)
            addEdge(x0 - rnx, y0 - rny, x0 + rnx, y0 + rny)
            if x_hi2 >= x_lo2 then
                if x_lo2 < x_lo then x_lo = x_lo2 end
                if x_hi2 > x_hi then x_hi = x_hi2 end
            end
        else
            -- 水平线段:条带主体 = [x0,x1] 全宽(端盖圆盘已并入)
            if math.abs(y - y0) <= r then
                if x0 < x_lo then x_lo = x0 end
                if x1 > x_hi then x_hi = x1 end
            end
        end
        if x_hi >= x_lo then
            local xa = math.max(0, math.floor(x_lo))
            local xb = math.min(bw, math.ceil(x_hi))
            if xb >= xa then
                bb:paintRect(xa, y, xb - xa + 1, 1, color)
            end
        end
    end
end

-- 粗线段:circle 走扫描线条带填充(边缘平滑);非圆笔触沿线段按间距 ~width/2 采样笔触
-- 形状(保持形状可辨又连续)。tip 缺省 = circle,向后兼容
function shapes.thickLine(bb, x0, y0, x1, y1, width, color, tip)
    width = width or 4
    local dx, dy = x1 - x0, y1 - y0
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.001 then
        shapes.tip(bb, x0, y0, width, color, tip)
        return
    end
    if tip ~= nil and tip ~= "circle" then
        local step = math.max(2, math.floor(width / 2))
        local n = math.max(1, math.ceil(dist / step))
        for i = 0, n do
            local t = i / n
            shapes.tip(bb, x0 + dx * t, y0 + dy * t, width, color, tip)
        end
        return
    end
    shapes.thickLineFill(bb, x0, y0, x1, y1, width, color)
end

-- Catmull-Rom 样条段 P1→P2(过点插值、切向连续):P0/P3 为两侧邻点,决定端点切向,
-- 端点外侧用相邻点复制(P0=P1 或 P3=P2)。按 ~2px 弧长采样成短 thickLine
-- (圆头笔触保证段间无缝)。相比中点二次曲线(近似二次 B 样条,会在每个采样点处切角),
-- 过点插值在稀疏采样的闭合曲线(小圆圈)上保持圆滑——8~10 个采样点即可画出圆。
-- 控制点共线时退化为直线,零长度段安全(t=0 起点即 P1)。
function shapes.crSegment(bb, p0, p1, p2, p3, width, color, tip)
    local approx = math.abs(p1.x - p2.x) + math.abs(p1.y - p2.y)
    local steps = math.max(2, math.min(64, math.floor(approx / 2)))
    local px = math.floor(p1.x)
    local py = math.floor(p1.y)
    for i = 1, steps do
        local t = i / steps
        local t2 = t * t
        local t3 = t2 * t
        local qx = math.floor(0.5 * (2 * p1.x + (-p0.x + p2.x) * t
            + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
            + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3))
        local qy = math.floor(0.5 * (2 * p1.y + (-p0.y + p2.y) * t
            + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
            + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3))
        if qx ~= px or qy ~= py then
            shapes.thickLine(bb, px, py, qx, qy, width, color, tip)
            px, py = qx, qy
        end
    end
end

-- 折线(自由画笔/橡皮);ox/oy 为整体偏移(预览画在屏幕 BB 上时用)。
-- Catmull-Rom 过点平滑:首点笔触 → 每相邻两点一段 cr(P[i-1],P[i],P[i+1],P[i+2])
-- (端点邻位钳到首/末点),曲线精确通过每个采样点。
-- 与 strokes.lua 的增量渲染(_renderStrokeTail/_renderStrokeClose)逐段一致:
-- 实时笔迹与重绘完全相同。
function shapes.polyline(bb, points, width, color, ox, oy, tip)
    ox = ox or 0
    oy = oy or 0
    local n = #points
    if n == 0 then return end
    if n == 1 then
        shapes.tip(bb, points[1].x + ox, points[1].y + oy, width, color, tip)
        return
    end
    -- 起点笔触(全宽:起笔即全宽,起笔处的小圆弧清晰可见)
    shapes.tip(bb, points[1].x + ox, points[1].y + oy, width, color, tip)
    for i = 1, n - 1 do
        local p0 = points[math.max(1, i - 1)]
        local p1 = points[i]
        local p2 = points[i + 1]
        local p3 = points[math.min(n, i + 2)]
        shapes.crSegment(bb,
            { x = p0.x + ox, y = p0.y + oy },
            { x = p1.x + ox, y = p1.y + oy },
            { x = p2.x + ox, y = p2.y + oy },
            { x = p3.x + ox, y = p3.y + oy },
            width, color, tip)
    end
end

-- 矩形框(仅描边):4 条粗边
function shapes.rect(bb, x0, y0, x1, y1, width, color, tip)
    local xa, xb = math.min(x0, x1), math.max(x0, x1)
    local ya, yb = math.min(y0, y1), math.max(y0, y1)
    shapes.thickLine(bb, xa, ya, xb, ya, width, color, tip)
    shapes.thickLine(bb, xb, ya, xb, yb, width, color, tip)
    shapes.thickLine(bb, xb, yb, xa, yb, width, color, tip)
    shapes.thickLine(bb, xa, yb, xa, ya, width, color, tip)
end

-- 椭圆描边:环带扫描线填充(外椭圆 rx+w/2 与内椭圆 rx-w/2 之间逐行填充)。
-- 比"周采样点连粗线"平滑——任意旋转/线宽下轮廓连续,无采样多边形化锯齿。
-- 旋转椭圆在扫描线上的 x 区间由局部椭圆方程 A·dx²+B·dx+C≤0 解出。
function shapes.ellipse(bb, cx, cy, rx, ry, width, color, tip, rot)
    rx = math.max(0.5, rx or 1)
    ry = math.max(0.5, ry or rx)
    if rx < 1 and ry < 1 then
        shapes.tip(bb, cx, cy, width, color, tip)
        return
    end
    if tip ~= nil and tip ~= "circle" then
        -- 非圆笔触(画笔画圆):保持旧周采样连线
        local cosr, sinr = math.cos(rot or 0), math.sin(rot or 0)
        local function point(a)
            local px, py = cx + rx * math.cos(a), cy + ry * math.sin(a)
            local dx, dy = px - cx, py - cy
            return cx + dx * cosr - dy * sinr, cy + dx * sinr + dy * cosr
        end
        local step = math.max(2, math.floor(width / 2))
        local n = math.max(24, math.ceil(2 * math.pi * math.max(rx, ry) / step))
        local prev_x, prev_y = point(0)
        for i = 1, n do
            local a = 2 * math.pi * i / n
            local px, py = point(a)
            shapes.thickLine(bb, prev_x, prev_y, px, py, width, color, tip)
            prev_x, prev_y = px, py
        end
        return
    end
    -- 环带:外椭圆 = rx+w/2,内椭圆 = rx-w/2(太细时退化实心)
    local w2 = math.max(0.5, width / 2)
    local ro_rx, ro_ry = rx + w2, ry + w2
    local ri_rx, ri_ry = math.max(0.2, rx - w2), math.max(0.2, ry - w2)
    local cosr, sinr = math.cos(rot or 0), math.sin(rot or 0)
    local c2, s2 = cosr * cosr, sinr * sinr
    -- 外椭圆 AABB 半高(旋转):sqrt(ro_rx²·s² + ro_ry²·c²)
    local half_h = math.sqrt(ro_rx * ro_rx * s2 + ro_ry * ro_ry * c2)
    local y_min = math.max(0, math.floor(cy - half_h))
    local y_max = math.min(bb:getHeight() - 1, math.ceil(cy + half_h))
    local bw = bb:getWidth() - 1
    for y = y_min, y_max do
        local dy = y - cy
        local function xInterval(a_rx, a_ry)
            local A = c2 / (a_rx * a_rx) + s2 / (a_ry * a_ry)
            local B = 2 * dy * cosr * sinr * (1 / (a_rx * a_rx) - 1 / (a_ry * a_ry))
            local C = dy * dy * (s2 / (a_rx * a_rx) + c2 / (a_ry * a_ry)) - 1
            local disc = B * B - 4 * A * C
            if disc < 0 then
                return nil
            end
            local sq = math.sqrt(disc)
            return (-B - sq) / (2 * A), (-B + sq) / (2 * A)
        end
        local o_lo, o_hi = xInterval(ro_rx, ro_ry)
        if o_lo then
            local i_lo, i_hi = xInterval(ri_rx, ri_ry)
            if not i_lo then
                -- xInterval 返回相对中心的 dx,转绝对 x 需加 cx
                local xa = math.max(0, math.floor(cx + o_lo))
                local xb = math.min(bw, math.ceil(cx + o_hi))
                if xb >= xa then
                    bb:paintRect(xa, y, xb - xa + 1, 1, color)
                end
            else
                if o_lo < i_lo then
                    local xa = math.max(0, math.floor(cx + o_lo))
                    local xb = math.min(bw, math.ceil(cx + i_lo))
                    if xb >= xa then
                        bb:paintRect(xa, y, xb - xa + 1, 1, color)
                    end
                end
                if o_hi > i_hi then
                    local xa = math.max(0, math.floor(cx + i_hi))
                    local xb = math.min(bw, math.ceil(cx + o_hi))
                    if xb >= xa then
                        bb:paintRect(xa, y, xb - xa + 1, 1, color)
                    end
                end
            end
        end
    end
end

function shapes.circle(bb, cx, cy, r, width, color, tip)
    shapes.ellipse(bb, cx, cy, r, r, width, color, tip, 0)
end

-- 实心矩形:填充归一化区域(裁剪到画布)
function shapes.fillRect(bb, x0, y0, x1, y1, color)
    local xa, xb = math.min(x0, x1), math.max(x0, x1)
    local ya, yb = math.min(y0, y1), math.max(y0, y1)
    xa, ya = math.max(math.floor(xa), 0), math.max(math.floor(ya), 0)
    xb, yb = math.min(math.ceil(xb), bb:getWidth() - 1), math.min(math.ceil(yb), bb:getHeight() - 1)
    if xb < xa or yb < ya then
        return
    end
    bb:paintRect(xa, ya, xb - xa + 1, yb - ya + 1, color)
end

-- 实心圆:逐行扫描填充(裁剪到画布)
function shapes.fillCircle(bb, cx, cy, r, color)
    shapes.fillEllipse(bb, cx, cy, r, r, color)
end

-- 实心椭圆(未旋转):逐行扫描填充(裁剪到画布)
function shapes.fillEllipse(bb, cx, cy, rx, ry, color)
    rx = math.max(1, rx)
    ry = math.max(1, ry)
    local min_y = math.max(0, math.floor(cy - ry))
    local max_y = math.min(bb:getHeight() - 1, math.ceil(cy + ry))
    for y = min_y, max_y do
        local t = (y - cy) / ry
        local half = rx * math.sqrt(math.max(0, 1 - t * t))
        local x0 = math.max(0, math.floor(cx - half))
        local x1 = math.min(bb:getWidth() - 1, math.ceil(cx + half))
        if x1 >= x0 then
            bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
        end
    end
end

-- 实心椭圆(任意旋转):周长 ~1px/点 高采样成多边形走扫描线(偶奇配对),
-- 与 fillEllipse 同视觉;拉伸成旋转椭圆的实心形状不再退化描边。
function shapes.fillRotatedEllipse(bb, cx, cy, rx, ry, rot, color)
    rx = math.max(1, rx)
    ry = math.max(1, ry)
    -- 采样数 ≈ 周长(2π·√((rx²+ry²)/2) 的粗近似,按 (rx+ry)·π/2 计),钳 32~512
    local n = math.max(32, math.min(512, math.ceil((rx + ry) * 1.6)))
    local c, s = math.cos(rot), math.sin(rot)
    local pts = {}
    for i = 1, n do
        local t = (i - 1) / n * 2 * math.pi
        local ex, ey = rx * math.cos(t), ry * math.sin(t)
        pts[i] = { cx + ex * c - ey * s, cy + ex * s + ey * c }
    end
    local bw, bh = bb:getWidth(), bb:getHeight()
    local rows = shapes.polyRowSpans(pts)
    for y, list in pairs(rows) do
        if y >= 0 and y < bh then
            for _, iv in ipairs(list) do
                local x0 = math.max(0, iv[1])
                local x1 = math.min(bw - 1, iv[2])
                if x1 >= x0 then
                    bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
                end
            end
        end
    end
end

-- 多边形逐行扫描线栅格化(偶奇配对):返回 { [行号] = { {xa, xb}, ... }, ... },
-- 每行的区间已按 x 升序(与 _polygonFillSpans 相同取整规则:ceil(x-0.5)/floor(x+0.5))。
-- fill 旋转时把每个 span 旋转后的平行四边形带重栅格化回 span 列表用(geometry._rotateElement)。
-- 输入点用 {x, y} 数组形式(避免依赖元素点表结构)
function shapes.polyRowSpans(pts)
    local rows = {}
    local n = #pts
    if n < 3 then
        return rows
    end
    local y_min, y_max = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[2] < y_min then y_min = p[2] end
        if p[2] > y_max then y_max = p[2] end
    end
    for y = math.floor(y_min), math.ceil(y_max) do
        local xs = {}
        for i = 1, n do
            local a, b = pts[i], pts[(i % n) + 1]
            if (a[2] <= y and b[2] > y) or (b[2] <= y and a[2] > y) then
                table.insert(xs, a[1] + (y - a[2]) * (b[1] - a[1]) / (b[2] - a[2]))
            end
        end
        table.sort(xs)
        local list = {}
        local i = 1
        while i < #xs do
            local x0 = math.ceil(xs[i] - 0.5)
            local x1 = math.floor(xs[i + 1] + 0.5)
            if x1 >= x0 then
                table.insert(list, { x0, x1 })
            end
            i = i + 2
        end
        if #list > 0 then
            rows[y] = list
        end
    end
    return rows
end

-- 多边形活动边表(AET)扫描线栅格化:返回 { [行号] = { {xa, xb}, ... }, ... }。
-- 与 polyRowSpans 结果相同,但每条边只在它的 y 范围被处理一次,每行只遍历活动边
-- (跨该行的边,通常 2-4 条)——fill 旋转时对锯齿轮廓(顶点=每行边界点,数百上千条边)
-- 逐行扫描的开销从 O(边数×行数) 降到 O(边数+行数×活动边数),大 fill 拖拽旋转不卡。
-- 输入点用 {x, y} 数组形式(闭合多边形);水平边跳过;构建边表时合并首尾相连的共线边
-- (fill 轮廓的竖直锯齿边在旋转 90°/180° 后重叠成同一条,不合并会在顶点处重复计数);
-- 边覆盖 [y0,y1] 闭区间——顶点所在行也产生覆盖,旋转 180° 后栅格化结果稳定
-- (半开区间会丢顶行、旋转翻转后 bbox 抖动)。
function shapes.polyRowsAET(pts)
    local rows = {}
    local n = #pts
    if n < 3 then
        return rows
    end
    local edges = {}
    local function add_edge(a, b)
        local dy = b[2] - a[2]
        if math.abs(dy) < 1e-9 then
            return -- 水平/近水平边不参与交点(近水平边 dy≈0 → slope 巨大,
            -- 参与共线合并会放大浮点误差,产生天文数字的 x0 平移/交点)
        end
        local y0, y1 = a[2], b[2]
        local x0 = a[1]
        if y0 > y1 then
            y0, y1, x0 = y1, y0, b[1]
        end
        local slope = (b[1] - a[1]) / dy
        local last = edges[#edges]
        -- 与上一条边首尾相连(顶点序列相邻)且斜率相同 = 共线,合并成一条。
        -- 连接点按顶点序列判断(规范化 y0/y1 后相邻边方向可能反转,不能按 y 接续判断);
        -- 合并后 y 范围取 min/max,并把 x0 平移到新 y0 处(x = x0 + slope*(y-y0))
        if last and last.ex == a[1] and last.ey == a[2]
            and math.abs(last.slope - slope) < 1e-9 then
            local ny0 = math.min(last.y0, y0)
            local ny1 = math.max(last.y1, y1)
            last.x0 = last.x0 + last.slope * (ny0 - last.y0)
            last.y0, last.y1 = ny0, ny1
            last.ex, last.ey = b[1], b[2]
        else
            table.insert(edges, { y0 = y0, y1 = y1, x0 = x0, slope = slope, ex = b[1], ey = b[2] })
        end
    end
    for i = 1, n do
        add_edge(pts[i], pts[(i % n) + 1])
    end
    if #edges < 2 then
        return rows
    end
    local y_min, y_max = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[2] < y_min then y_min = p[2] end
        if p[2] > y_max then y_max = p[2] end
    end
    table.sort(edges, function(a, b) return a.y0 < b.y0 end)
    local eidx = 1
    local aet = {}
    for t = math.floor(y_min), math.ceil(y_max) do
        local tt = t + 0.5 -- 行中心
        -- 1) 移除已结束边(闭区间:y1 < tt 结束)
        local w = 1
        for i = 1, #aet do
            local e = aet[i]
            if e.y1 >= tt then
                aet[w] = e
                w = w + 1
            end
        end
        for i = #aet, w, -1 do
            aet[i] = nil
        end
        -- 2) 加入新边(当前行交点)
        while eidx <= #edges and edges[eidx].y0 <= tt do
            local e = edges[eidx]
            e.xcur = e.x0 + (tt - e.y0) * e.slope
            table.insert(aet, e)
            eidx = eidx + 1
        end
        -- 3) 配对输出当前行区间
        if #aet >= 2 then
            table.sort(aet, function(p, q) return p.xcur < q.xcur end)
            local list = {}
            local i = 1
            while i < #aet do
                local xa = math.ceil(aet[i].xcur - 0.5)
                local xb = math.floor(aet[i + 1].xcur + 0.5)
                if xb >= xa then
                    table.insert(list, { xa, xb })
                end
                i = i + 2
            end
            if #list > 0 then
                rows[t] = list
            end
        end
        -- 4) 活动边 x 推进到下一行(加入的边本轮已输出,不能再累加,否则交点超前一行)
        for i = 1, #aet do
            aet[i].xcur = aet[i].xcur + aet[i].slope
        end
    end
    return rows
end

-- 半透明渲染代理:拦截 paintRect,把墨色按 alpha(0-1)真混合到目标 BB 现有像素上
-- (dest = α·墨色 + (1-α)·dest):白底上等于变浅,叠在墨迹上则透出下层(纯灰度做不到)。
-- shapes 全部原语只用 paintRect/getWidth/getHeight(见文件头),代理包装即对全部元素生效。
-- 坐标/裁剪/负偏移交给 real:paintRect 原生处理;混合走 setPixelBlend 逐像素 setter。
-- ponytail: 逐像素 Lua setter,整幅大填充约 0.1s 级(仅提交/重绘时一次);不够快再换 getPixelP 指针循环
function shapes.alphaProxy(real, alpha)
    local Blitbuffer = require("ffi/blitbuffer")
    local a255 = math.max(0, math.min(255, math.floor(alpha * 255 + 0.5)))
    local blend_setter = real.setPixelBlend
    return {
        getWidth = function() return real:getWidth() end,
        getHeight = function() return real:getHeight() end,
        paintRect = function(_, x, y, w, h, value)
            local v = value:getColor8()
            real:paintRect(x, y, w, h, Blitbuffer.Color8A(v.a, a255), blend_setter)
        end,
    }
end

-- 按元素类型绘制(画布重放与屏幕预览共用);颜色由调用方传入,ox/oy 为整体偏移
function shapes.drawElement(bb, el, color, ox, oy)
    local kind = el.kind
    if kind == "fill" then
        -- 洪泛填充结果:逐行 span 复写(区域重绘/撤销重放精确还原)。
        -- 直接遍历 span:不同行的 span 互不影响(同行的多段互不重叠),不用按行聚表
        -- 再排序 —— 旧版每行建一个小表 + 排序,整幅背景填(上千行)每次重放上千次
        -- 分配;元素一多、每次落笔提交都重放一次,真机上就是"笔画多了刷新变慢"
        ox = ox or 0
        oy = oy or 0
        local bw, bh = bb:getWidth(), bb:getHeight()
        local spans = el.spans
        for i = 1, #spans do
            local sp = spans[i]
            local yy = sp[1] + oy
            if yy >= 0 and yy < bh then
                local xa = math.floor(sp[2]) + ox
                local xb = math.floor(sp[3]) + ox
                if xa < 0 then xa = 0 end
                if xb > bw - 1 then xb = bw - 1 end
                if xb >= xa then
                    bb:paintRect(xa, yy, xb - xa + 1, 1, color)
                end
            end
        end
    elseif kind == "freehand" or kind == "eraser" then
        shapes.polyline(bb, el.points, el.width, color, ox, oy, el.tip)
    elseif kind == "poly" then
        -- 多边形(旋转后的矩形):实心先扫描线填充(v61k:不再退化为空心)再闭合描边
        local pts = el.points
        local n = #pts
        if el.filled and n >= 3 then
            local poly = {}
            for i, p in ipairs(pts) do
                poly[i] = { p.x + (ox or 0), p.y + (oy or 0) }
            end
            local bw, bh = bb:getWidth(), bb:getHeight()
            local rows = shapes.polyRowSpans(poly)
            for y, list in pairs(rows) do
                if y >= 0 and y < bh then
                    for _, iv in ipairs(list) do
                        local x0 = math.max(0, iv[1])
                        local x1 = math.min(bw - 1, iv[2])
                        if x1 >= x0 then
                            bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
                        end
                    end
                end
            end
        end
        for i = 2, n do
            local a, b = pts[i - 1], pts[i]
            shapes.thickLine(bb, a.x + (ox or 0), a.y + (oy or 0),
                b.x + (ox or 0), b.y + (oy or 0), el.width, color, el.tip)
        end
        if n >= 3 then
            local a, b = pts[n], pts[1]
            shapes.thickLine(bb, a.x + (ox or 0), a.y + (oy or 0),
                b.x + (ox or 0), b.y + (oy or 0), el.width, color, el.tip)
        end
    elseif kind == "line" then
        shapes.thickLine(bb, el.x0 + (ox or 0), el.y0 + (oy or 0),
            el.x1 + (ox or 0), el.y1 + (oy or 0), el.width, color, el.tip)
    elseif kind == "rect" then
        if el.filled then
            shapes.fillRect(bb, el.x0 + (ox or 0), el.y0 + (oy or 0),
                el.x1 + (ox or 0), el.y1 + (oy or 0), color)
        end
        shapes.rect(bb, el.x0 + (ox or 0), el.y0 + (oy or 0),
            el.x1 + (ox or 0), el.y1 + (oy or 0), el.width, color, el.tip)
    elseif kind == "circle" then
        -- 圆/椭圆:rx/ry 支持非等比缩放成椭圆,rot 支持旋转(实心旋转椭圆扫描线填充)
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local rot = el.rot or 0
        if el.filled then
            if rot == 0 then
                shapes.fillEllipse(bb, el.cx + (ox or 0), el.cy + (oy or 0), rx, ry, color)
            else
                shapes.fillRotatedEllipse(bb, el.cx + (ox or 0), el.cy + (oy or 0), rx, ry, rot, color)
            end
        end
        shapes.ellipse(bb, el.cx + (ox or 0), el.cy + (oy or 0), rx, ry, el.width, color, el.tip, rot)
    end
end

return shapes
