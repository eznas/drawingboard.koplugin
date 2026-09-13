--[[--
drawingpad.geometry — 几何计算与变换方法(DrawingCanvas 混合模块)。
纯坐标/区域/包围盒计算与元素几何变换,不依赖具体 UI 状态之外的对象。
文字包围盒按实际渲染尺寸计算(RenderText:sizeUtf8Text),锚点框完整覆盖文字,
移动/变形不再留残影。
--]]

local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")

-- 自定位:同目录短名 shapes/const 可解析(v53+ pluginloader 注入 <插件目录>/?.lua,
-- 短模式已够用;v57 去掉父目录双模式,wbuilder 路径在 wbuilder.lua 顶部单独注入)
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")

local M = {}

-- 屏幕坐标 → 画布坐标(画布坐标 = 屏幕坐标,保证最小化切换无位移);
-- 可见模式下底部(工具栏+状态栏)遮挡区不可画
function M:_toCanvas(px, py)
    if px < 0 or py < 0 or px >= self.canvas_w or py >= self.canvas_h then
        return nil
    end
    if not self._minimized and py >= self.canvas_h - self.header_h then
        return nil
    end
    return px, py
end

-- 笔画/预览包围盒刷新区域(屏幕坐标=画布坐标,含边距;返回 Geom 或 nil)
function M:_dirtyRegion(x0, y0, x1, y1, margin)
    margin = margin or 2
    local rx0 = math.max(0, math.floor(math.min(x0, x1)) - margin)
    local ry0 = math.max(0, math.floor(math.min(y0, y1)) - margin)
    local rx1 = math.min(self.canvas_w, math.ceil(math.max(x0, x1)) + margin)
    local ry1 = math.min(self.canvas_h, math.ceil(math.max(y0, y1)) + margin)
    if rx1 <= rx0 or ry1 <= ry0 then
        return nil
    end
    return Geom:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 }
end

-- 元素包围盒(画布坐标);返回 {x0,y0,x1,y1} 或 nil
-- 文字渲染尺寸(含 sx/sy 拉伸):返回 {w, yt, yb, baseline} 或 nil(face 缺失)。
-- 包围盒/选取框/墨迹距离/绘制共用,保证各处一致的"拉伸后"尺寸
function M:_textExtent(el)
    local face = Font:getFace(el.font, el.size)
    local s = face and RenderText:sizeUtf8Text(0, nil, face, el.text, false, false)
    if not (s and s.x and s.y_top and s.y_bottom) then
        return nil
    end
    return {
        w = s.x * (el.sx or 1),
        yt = s.y_top * (el.sy or 1),
        yb = s.y_bottom * (el.sy or 1),
        baseline = (el.y or 0) + math.floor(el.size * 0.8),
    }
end

function M:_elementBBox(el)
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    local function add(x0, y0, x1, y1)
        if x0 < minx then minx = x0 end
        if y0 < miny then miny = y0 end
        if x1 > maxx then maxx = x1 end
        if y1 > maxy then maxy = y1 end
    end
    if el.kind == "circle" then
        -- 圆/椭圆(含旋转)的外接轴对齐包围盒
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local rot = el.rot or 0
        if rot == 0 then
            add(el.cx - rx, el.cy - ry, el.cx + rx, el.cy + ry)
        else
            local c, s = math.abs(math.cos(rot)), math.abs(math.sin(rot))
            local hw = rx * c + ry * s
            local hh = rx * s + ry * c
            add(el.cx - hw, el.cy - hh, el.cx + hw, el.cy + hh)
        end
    elseif el.kind == "line" or el.kind == "rect" then
        add(math.min(el.x0, el.x1), math.min(el.y0, el.y1),
            math.max(el.x0, el.x1), math.max(el.y0, el.y1))
    elseif el.kind == "freehand" or el.kind == "eraser" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            add(p.x - el.width, p.y - el.width, p.x + el.width, p.y + el.width)
        end
    elseif el.kind == "fill" then
        -- 洪泛填充结果:span 列表 {y, x0, x1} 的包围盒
        for _, sp in ipairs(el.spans) do
            add(sp[2], sp[1], sp[3], sp[1])
        end
    elseif el.kind == "text" then
        if not el.text or not el.size then
            return nil
        end
        -- 优先按实际渲染尺寸算包围盒(锚点框完整覆盖文字,移动不残影);
        -- 字体缺失时回退字符数估算
        local nchars = select(2, el.text:gsub("[^\128-\191]", ""))
        local e = self:_textExtent(el)
        if e then
            local ax = el.x or 0
            local ay = e.baseline -- 旋转中心 = 基线(与 _drawTextTo/_frameCorners 同锚点)
            local rot = el.rot or 0
            if rot == 0 then
                add(ax - 1, e.baseline - e.yt - 1, ax + e.w + 1, e.baseline + e.yb + 1)
            else
                -- 旋转:4 个角绕锚点(基线左端)旋转后取外接框
                local c, sn = math.cos(rot), math.sin(rot)
                local function radd(px, py)
                    local dx, dy = px - ax, py - ay
                    add(ax + dx * c - dy * sn, ay + dx * sn + dy * c,
                        ax + dx * c - dy * sn, ay + dx * sn + dy * c)
                end
                radd(ax - 1, e.baseline - e.yt - 1)
                radd(ax + e.w + 1, e.baseline - e.yt - 1)
                radd(ax + e.w + 1, e.baseline + e.yb + 1)
                radd(ax - 1, e.baseline + e.yb + 1)
            end
            return { x0 = minx, y0 = miny, x1 = maxx, y1 = maxy }
        end
        add(el.x or 0, el.y or 0, (el.x or 0) + nchars * el.size, (el.y or 0) + math.ceil(el.size * 1.5))
    end
    if minx == math.huge then
        return nil
    end
    return { x0 = minx, y0 = miny, x1 = maxx, y1 = maxy }
end

-- 元素提交时缓存包围盒(元素一经提交不可变,缓存无失效问题)。
-- 点删预过滤/框删/保存裁剪/局部重绘都走缓存,不再每次扫描全部点表
function M:_cacheBBox(el)
    el._bbox = self:_elementBBox(el)
    return el._bbox
end

-- 元素完整刷新区域:圆以锚点为圆心、半径=拖动距离,会超出"锚点-释放点"包围盒,
-- 必须按元素实际范围(圆心±半径/对角线±线宽)计算,否则屏幕刷新不全、圆缺块
function M:_elementRegion(el, extra)
    extra = extra or 2
    local margin = (el.width or 2) + extra
    local b = self:_elementBBox(el)
    if not b then
        return nil
    end
    local rx0 = math.max(0, math.floor(b.x0) - margin)
    local ry0 = math.max(0, math.floor(b.y0) - margin)
    local rx1 = math.min(self.canvas_w, math.ceil(b.x1) + margin)
    local ry1 = math.min(self.canvas_h, math.ceil(b.y1) + margin)
    if rx1 <= rx0 or ry1 <= ry0 then
        return nil
    end
    return Geom:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 }
end

-- 合并两个刷新区域
function M:_mergeRegions(a, b)
    if not a then
        return b
    end
    if not b then
        return a
    end
    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- 元素内容包围盒(用于导出裁剪);返回 {x,y,w,h} 或 nil(无内容)
-- 走提交时缓存的 bbox:不再逐笔画扫描全部点表
function M:_contentBBox()
    local minx, miny, maxx, maxy = math.huge, math.huge, -1, -1
    local function add(x0, y0, x1, y1)
        if x0 < minx then minx = x0 end
        if y0 < miny then miny = y0 end
        if x1 > maxx then maxx = x1 end
        if y1 > maxy then maxy = y1 end
    end
    for li = 1, 3 do
        if self.layer_visible[li] then
            for _, el in ipairs(self.layers[li]) do
                local b = el._bbox or self:_elementBBox(el)
                if b then
                    add(b.x0, b.y0, b.x1, b.y1)
                end
            end
        end
    end
    if maxx < 0 then
        return nil
    end
    local pad = 8
    local x0 = math.max(0, math.floor(minx) - pad)
    local y0 = math.max(0, math.floor(miny) - pad)
    local x1 = math.min(self.canvas_w - 1, math.ceil(maxx) + pad)
    local y1 = math.min(self.canvas_h - 1, math.ceil(maxy) + pad)
    if x1 < x0 or y1 < y0 then
        return nil
    end
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- 平移元素坐标(各 kind 坐标字段;平移后需重算 bbox 缓存)
function M:_moveElement(el, dx, dy)
    if el.kind == "freehand" or el.kind == "eraser" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            p.x = p.x + dx
            p.y = p.y + dy
        end
    elseif el.kind == "line" or el.kind == "rect" then
        el.x0, el.y0 = el.x0 + dx, el.y0 + dy
        el.x1, el.y1 = el.x1 + dx, el.y1 + dy
    elseif el.kind == "circle" then
        el.cx, el.cy = el.cx + dx, el.cy + dy
    elseif el.kind == "text" then
        el.x = (el.x or 0) + dx
        el.y = (el.y or 0) + dy
    elseif el.kind == "fill" then
        -- 填充结果:平移 span 列表(每行 y/x0/x1);源顶点同步平移,
        -- 否则移动后再旋转会按旧顶点重算、填充跳回原位
        if el.src_points then
            for _, p in ipairs(el.src_points) do
                p.x = p.x + dx
                p.y = p.y + dy
            end
        end
        for _, sp in ipairs(el.spans) do
            sp[1] = sp[1] + dy
            sp[2] = sp[2] + dx
            sp[3] = sp[3] + dx
        end
    end
end

-- 复制元素(freehand 点表/spans 深拷贝;_bbox 不复制,提交时重算)
function M:_cloneElement(el)
    local c = {}
    for k, v in pairs(el) do
        if k == "points" or k == "src_points" then
            local pts = {}
            for i, p in ipairs(v) do
                pts[i] = { x = p.x, y = p.y }
            end
            c[k] = pts
        elseif k == "spans" then
            -- fill 的 span 列表深拷贝(移动/复制副本独立,不共享像素行)
            local sps = {}
            for i, sp in ipairs(v) do
                sps[i] = { sp[1], sp[2], sp[3] }
            end
            c.spans = sps
        elseif k ~= "_bbox" then
            c[k] = v
        end
    end
    return c
end

-- 用几何快照恢复元素(撤销/重做变形用;points 深拷贝,避免快照被后续修改污染)
function M:_restoreGeom(el, snap)
    for k in pairs(el) do
        if k ~= "_bbox" then
            el[k] = nil
        end
    end
    for k, v in pairs(snap) do
        if k == "points" or k == "src_points" then
            local pts = {}
            for i, p in ipairs(v) do
                pts[i] = { x = p.x, y = p.y }
            end
            el[k] = pts
        elseif k ~= "_bbox" then
            el[k] = v
        end
    end
end

-- 按锚点与新位置计算新包围盒(对角/单轴固定;最小尺寸 4px)
function M:_transformBBox(handle, sb, x, y)
    local min_size = 4
    local x0, y0, x1, y1 = sb.x0, sb.y0, sb.x1, sb.y1
    if handle == "nw" then
        return { x0 = math.min(x, x1 - min_size), y0 = math.min(y, y1 - min_size), x1 = x1, y1 = y1 }
    elseif handle == "ne" then
        return { x0 = x0, y0 = math.min(y, y1 - min_size), x1 = math.max(x, x0 + min_size), y1 = y1 }
    elseif handle == "sw" then
        return { x0 = math.min(x, x1 - min_size), y0 = y0, x1 = x1, y1 = math.max(y, y0 + min_size) }
    elseif handle == "se" then
        return { x0 = x0, y0 = y0, x1 = math.max(x, x0 + min_size), y1 = math.max(y, y0 + min_size) }
    elseif handle == "n" then
        return { x0 = x0, y0 = math.min(y, y1 - min_size), x1 = x1, y1 = y1 }
    elseif handle == "s" then
        return { x0 = x0, y0 = y0, x1 = x1, y1 = math.max(y, y0 + min_size) }
    elseif handle == "w" then
        return { x0 = math.min(x, x1 - min_size), y0 = y0, x1 = x1, y1 = y1 }
    elseif handle == "e" then
        return { x0 = x0, y0 = y0, x1 = math.max(x, x0 + min_size), y1 = y1 }
    end
    return sb
end

-- 缩放元素几何:起始包围盒 → 新包围盒 双线性映射坐标
-- (文字缩放 = 位置映射 + 均匀部分进字号(保清晰)+ 残余非均匀进 sx/sy 像素缩放;
-- 圆/椭圆 = 中心映射 + rx/ry 各轴因子 → 椭圆)
function M:_scaleElement(el, sb, nb)
    local sx = (nb.x1 - nb.x0) / math.max(1, sb.x1 - sb.x0)
    local sy = (nb.y1 - nb.y0) / math.max(1, sb.y1 - sb.y0)
    local function map(px, py)
        return nb.x0 + (px - sb.x0) * sx, nb.y0 + (py - sb.y0) * sy
    end
    if el.kind == "freehand" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            p.x, p.y = map(p.x, p.y)
        end
    elseif el.kind == "line" then
        el.x0, el.y0 = map(el.x0, el.y0)
        el.x1, el.y1 = map(el.x1, el.y1)
    elseif el.kind == "rect" then
        el.x0, el.y0 = map(el.x0, el.y0)
        el.x1, el.y1 = map(el.x1, el.y1)
    elseif el.kind == "circle" then
        -- 圆/椭圆:中心映射,rx/ry 按各轴因子缩放(非等比 → 椭圆)
        el.cx, el.cy = map(el.cx, el.cy)
        el.rx = math.max(1, (el.rx or el.r) * sx)
        el.ry = math.max(1, (el.ry or el.rx or el.r) * sy)
    elseif el.kind == "text" then
        -- 均匀部分进字号(字形清晰),残余非均匀进 sx/sy(渲染时像素缩放成拉伸字形)
        local f = (sx + sy) / 2
        el.x, el.y = map(el.x, el.y)
        el.size = math.max(1, math.floor(el.size * f + 0.5))
        local denom = math.max(0.0001, f)
        el.sx = (el.sx or 1) * (sx / denom)
        el.sy = (el.sy or 1) * (sy / denom)
    elseif el.kind == "fill" then
        -- 有源顶点的路径填充:直接对顶点做同一双线性映射后重算 spans,
        -- 与首次生成同一条扫描线代码;每次变换都从连续几何出发,无累积量化。
        -- (无 src_points 的 tap 洪水填充/旧存档无几何可依,维持 span 映射)
        if el.src_points then
            for _, p in ipairs(el.src_points) do
                p.x, p.y = map(p.x, p.y)
            end
            el.spans = self:_polygonFillSpans(el.src_points)
            return
        end
        -- 填充结果:按新 bbox 缩放 span 列表。
        -- 拉大(sy>1)时源行不能只映射到单个目标行——相邻源行的目标行之间会留空行,
        -- 形成密集横纹;改为按源行纵向半行范围 [y-0.5, y+0.5] 映射后的目标行带铺满,
        -- 相邻源行的带在边界相接/重叠,行集连续。缩小(sy<1)保持逐行映射,
        -- 多源行并进同一目标行,由下方合并逻辑处理。
        local new_spans = {}
        local rows = {}
        local ylo, yhi
        if sy >= 1 then
            ylo = function(y) return math.ceil(sb.y0 + (y - 0.5 - sb.y0) * sy) end
            yhi = function(y) return math.floor(sb.y0 + (y + 0.5 - sb.y0) * sy) end
        else
            ylo = function(y) return math.floor(sb.y0 + (y - sb.y0) * sy + 0.5) end
            yhi = ylo
        end
        for _, sp in ipairs(el.spans) do
            local y, x0, x1 = sp[1], sp[2], sp[3]
            local nx0 = math.floor(sb.x0 + (x0 - sb.x0) * sx + 0.5)
            local nx1 = math.floor(sb.x0 + (x1 - sb.x0) * sx + 0.5)
            local xa, xb = math.min(nx0, nx1), math.max(nx0, nx1)
            for t = ylo(y), yhi(y) do
                local row = rows[t]
                if not row then
                    row = {}
                    rows[t] = row
                end
                table.insert(row, { xa, xb })
            end
        end
        for y, list in pairs(rows) do
            table.sort(list, function(a, b) return a[1] < b[1] end)
            local merged = {}
            local cur = list[1]
            for i = 2, #list do
                local s = list[i]
                if s[1] <= cur[2] + 1 then
                    cur[2] = math.max(cur[2], s[2])
                else
                    table.insert(merged, cur)
                    cur = s
                end
            end
            table.insert(merged, cur)
            for _, s in ipairs(merged) do
                table.insert(new_spans, { y, s[1], s[2] })
            end
        end
        el.spans = new_spans
        -- 变形后标记为栅格化填充:重放时补 1px 重叠，避免取整白线
        el._rasterized = true
    end
end

-- 按对象自身旋转外接框(OBB)做角锚缩放:拖 OBB 角到 (x,y),对角固定,
-- 沿 OBB 两轴分别求缩放因子并应用。
-- 旋转对象(椭圆 rot≠0/poly/文字 rot≠0)的缩放锚点在 OBB 角上、位于 AABB 内部,
-- 若仍用 AABB 的 _transformBBox/_scaleElement,向外拖 OBB 角释放点也超不过 AABB,
-- 对象只能缩小无法拉大。非旋转形状(锚在 AABB 角上)返回 false 走旧路径。
function M:_scaleElementOriented(el, handle, x, y)
    local F, ux, uy, vx, vy
    if el.kind == "circle" then
        if (el.rot or 0) == 0 then
            return false
        end
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local c, s = math.cos(el.rot), math.sin(el.rot)
        ux, uy, vx, vy = c, s, -s, c
        F = {
            { el.cx + rx * c - ry * s, el.cy + rx * s + ry * c },
            { el.cx + rx * c + ry * s, el.cy + rx * s - ry * c },
            { el.cx - rx * c + ry * s, el.cy - rx * s - ry * c },
            { el.cx - rx * c - ry * s, el.cy - rx * s + ry * c },
        }
    elseif el.kind == "poly" then
        F = {}
        for i, p in ipairs(el.points) do
            F[i] = { p.x, p.y }
        end
        if #F < 4 then
            return false
        end
        local d1x, d1y = F[2][1] - F[1][1], F[2][2] - F[1][2]
        local d2x, d2y = F[4][1] - F[1][1], F[4][2] - F[1][2]
        local l1 = math.sqrt(d1x * d1x + d1y * d1y)
        local l2 = math.sqrt(d2x * d2x + d2y * d2y)
        if l1 < 0.001 or l2 < 0.001 then
            return false
        end
        ux, uy, vx, vy = d1x / l1, d1y / l1, d2x / l2, d2y / l2
    elseif el.kind == "text" then
        if (el.rot or 0) == 0 then
            return false
        end
        local e = self:_textExtent(el)
        if not e then
            return false
        end
        local c, s = math.cos(el.rot), math.sin(el.rot)
        ux, uy, vx, vy = c, s, -s, c
        local ax, ay = el.x or 0, el.y or 0
        local b = e.baseline
        F = {
            { ax - 1, b - e.yt - 1 },
            { ax + e.w + 1, b - e.yt - 1 },
            { ax + e.w + 1, b + e.yb + 1 },
            { ax - 1, b + e.yb + 1 },
        }
        for _, p in ipairs(F) do
            local dx, dy = p[1] - ax, p[2] - ay
            p[1], p[2] = ax + dx * c - dy * s, ay + dx * s + dy * c
        end
    else
        return false
    end
    -- 拖角索引与固定对角(对角固定:nw↔se, ne↔sw)
    local i = handle == "nw" and 1 or handle == "ne" and 2
        or handle == "se" and 3 or handle == "sw" and 4 or 3
    local j = ((i + 1) % 4) + 1
    local pj = F[j]
    local pi = F[i]
    -- 对角向量在 OBB 两轴上的投影与拖到 (x,y) 的投影
    local d_ux = (pi[1] - pj[1]) * ux + (pi[2] - pj[2]) * uy
    local d_vx = (pi[1] - pj[1]) * vx + (pi[2] - pj[2]) * vy
    if math.abs(d_ux) < 0.001 or math.abs(d_vx) < 0.001 then
        return false
    end
    local fu = math.max(0.05, ((x - pj[1]) * ux + (y - pj[2]) * uy) / d_ux)
    local fv = math.max(0.05, ((x - pj[1]) * vx + (y - pj[2]) * vy) / d_vx)
    if el.kind == "circle" then
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        el.rx = math.max(1, rx * fu)
        el.ry = math.max(1, ry * fv)
        -- 中心移到对角固定的中点: C' = Pj + (d'u/2)u + (d'v/2)v
        el.cx = pj[1] + ((x - pj[1]) * ux + (y - pj[2]) * uy) / 2 * ux
            + ((x - pj[1]) * vx + (y - pj[2]) * vy) / 2 * vx
        el.cy = pj[2] + ((x - pj[1]) * ux + (y - pj[2]) * uy) / 2 * uy
            + ((x - pj[1]) * vx + (y - pj[2]) * vy) / 2 * vy
    elseif el.kind == "poly" then
        for _, p in ipairs(el.points) do
            local a = (p.x - pj[1]) * ux + (p.y - pj[2]) * uy
            local b = (p.x - pj[1]) * vx + (p.y - pj[2]) * vy
            p.x = pj[1] + a * fu * ux + b * fv * vx
            p.y = pj[2] + a * fu * uy + b * fv * vy
        end
    elseif el.kind == "text" then
        -- 均匀部分进字号(字形清晰),残余非均匀进 sx/sy(与 _scaleElement 同套路)
        local f = (fu + fv) / 2
        el.size = math.max(1, math.floor(el.size * f + 0.5))
        local denom = math.max(0.0001, f)
        el.sx = (el.sx or 1) * (fu / denom)
        el.sy = (el.sy or 1) * (fv / denom)
        -- 锚点(基线左端)相对固定角在 OBB 两轴上的偏移按因子缩放
        local ax, ay = el.x or 0, el.y or 0
        local a_ux = (ax - pj[1]) * ux + (ay - pj[2]) * uy
        local a_vx = (ax - pj[1]) * vx + (ay - pj[2]) * vy
        el.x = pj[1] + a_ux * fu * ux + a_vx * fv * vx
        el.y = pj[2] + a_ux * fu * uy + a_vx * fv * vy
    end
    return true
end

-- 旋转元素几何:绕 (cx,cy) 旋转 angle 弧度。
-- 矩形旋转 → 转为 poly(4 个旋转角点,闭合描边;实心退化为描边)
-- 椭圆旋转 → 记录 rot(渲染时绕中心旋转采样点)
function M:_rotateElement(el, angle, cx, cy)
    local cos, sin = math.cos(angle), math.sin(angle)
    local function rot(px, py)
        local dx, dy = px - cx, py - cy
        return cx + dx * cos - dy * sin, cy + dx * sin + dy * cos
    end
    if el.kind == "freehand" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            p.x, p.y = rot(p.x, p.y)
        end
    elseif el.kind == "line" then
        el.x0, el.y0 = rot(el.x0, el.y0)
        el.x1, el.y1 = rot(el.x1, el.y1)
    elseif el.kind == "circle" then
        el.rot = (el.rot or 0) + angle
    elseif el.kind == "text" then
        -- 文字旋转:累积角度 + 锚点(基线左端)绕旋转中心同步旋转
        -- (锚点+角度同步 = 刚性旋转一致,渲染绕锚点按 el.rot 旋转)
        el.rot = (el.rot or 0) + angle
        el.x, el.y = rot(el.x or 0, el.y or 0)
    elseif el.kind == "rect" then
        local pts = {
            { x = el.x0, y = el.y0 },
            { x = el.x1, y = el.y0 },
            { x = el.x1, y = el.y1 },
            { x = el.x0, y = el.y1 },
        }
        for _, p in ipairs(pts) do
            p.x, p.y = rot(p.x, p.y)
        end
        el.kind = "poly"
        el.points = pts
        -- 保留 filled：旋转后的实心矩形仍应保持实心
    elseif el.kind == "fill" then
        -- 有源顶点的路径填充:顶点精确旋转后用首次生成同一条扫描线
        -- (_polygonFillSpans,半开区间+像素中心取整)重算 spans。
        -- 每次变换都从连续几何出发,不像 span 反建路径那样逐次向外漂移
        -- (棘轮:±0.5 外扩+顶点行覆盖 → 旋转多次后穿模细线)。
        if el.src_points then
            for _, p in ipairs(el.src_points) do
                p.x, p.y = rot(p.x, p.y)
            end
            el.spans = self:_polygonFillSpans(el.src_points)
            return
        end
        -- 无 src_points(tap 洪水填充/旧存档):只能从量化 span 反建几何。
        -- 每个 span 是半行厚矩形 [x0-0.5,x1+0.5]×[y-0.5,y+0.5]。
        -- 快路径(每行单段且行连续):重建区域轮廓(顶点=行边界点)旋转后走活动边表扫描,
        -- 每行只处理常数条活动边,大 fill 拖拽旋转预览每帧重算不卡;
        -- 慢路径(多段/断行):相邻同宽 span 垂直合并成矩形块逐块旋转扫描(结果一致)。
        -- 相邻块的共享边界旋转后仍共享,行间无缝隙;同目标行区间合并重叠/相邻段。
        -- 结果烧录进 spans(无 rot 字段)。
        local sorted = {}
        for _, sp in ipairs(el.spans) do
            table.insert(sorted, sp)
        end
        table.sort(sorted, function(a, b) return a[1] < b[1] end)
        local rows = {}
        -- 变形后的路径填充禁止锯齿轮廓快路径：逐行轮廓在旋转后容易自交，
        -- 产生脱离边界的密集线条；慢路径按相邻矩形块重栅格化更稳。
        local single = (not el._rasterized) and #sorted >= 2
        if single then
            for i = 2, #sorted do
                local prev, cur = sorted[i - 1], sorted[i]
                if cur[1] == prev[1] or cur[1] ~= prev[1] + 1 then
                    single = false
                    break
                end
            end
        end
        if single then
            -- 区域轮廓:顶边 → 右锯齿 → 底边 → 左锯齿(闭合),旋转后 AET 扫描
            local n = #sorted
            local ymin, ymax = sorted[1][1], sorted[n][1]
            local pts = {}
            local function push(px, py)
                table.insert(pts, { px, py })
            end
            push(sorted[1][2] - 0.5, ymin - 0.5)
            push(sorted[1][3] + 0.5, ymin - 0.5)
            for i = 1, n do
                push(sorted[i][3] + 0.5, sorted[i][1] + 0.5)
            end
            push(sorted[n][2] - 0.5, ymax + 0.5)
            for i = n, 1, -1 do
                push(sorted[i][2] - 0.5, sorted[i][1] - 0.5)
            end
            for _, p in ipairs(pts) do
                p[1], p[2] = rot(p[1], p[2])
            end
            rows = shapes.polyRowsAET(pts)
        else
            -- 多段/断行:同宽相邻行合并成矩形块,逐块旋转后扫描线栅格化
            local blocks = {}
            for _, sp in ipairs(sorted) do
                local y, x0, x1 = sp[1], sp[2], sp[3]
                local last = blocks[#blocks]
                if last and y == last.y1 + 1 and x0 == last.x0 and x1 == last.x1 then
                    last.y1 = y
                else
                    table.insert(blocks, { y0 = y, y1 = y, x0 = x0, x1 = x1 })
                end
            end
            for _, blk in ipairs(blocks) do
                local x0, x1, y0, y1 = blk.x0 - 0.5, blk.x1 + 0.5, blk.y0 - 0.5, blk.y1 + 0.5
                local p1x, p1y = rot(x0, y0)
                local p2x, p2y = rot(x1, y0)
                local p3x, p3y = rot(x1, y1)
                local p4x, p4y = rot(x0, y1)
                local rspans = shapes.polyRowSpans({ { p1x, p1y }, { p2x, p2y }, { p3x, p3y }, { p4x, p4y } })
                for t, list in pairs(rspans) do
                    local row = rows[t]
                    if not row then
                        row = {}
                        rows[t] = row
                    end
                    for _, iv in ipairs(list) do
                        table.insert(row, iv)
                    end
                end
            end
        end
        local new_spans = {}
        for t, list in pairs(rows) do
            table.sort(list, function(a, b) return a[1] < b[1] end)
            local merged = {}
            local cur = list[1]
            for i = 2, #list do
                local s = list[i]
                if s[1] <= cur[2] + 1 then
                    cur[2] = math.max(cur[2], s[2])
                else
                    table.insert(merged, cur)
                    cur = s
                end
            end
            table.insert(merged, cur)
            for _, s in ipairs(merged) do
                table.insert(new_spans, { t, s[1], s[2] })
            end
        end
        el.spans = new_spans
        -- 变形后标记为栅格化填充:重放时做 1px 边界重叠,消除取整缝隙
        el._rasterized = true
    end
end

return M
