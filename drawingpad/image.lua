--[[--
drawingpad.image — 图片对象(kind="image")导入与像素管理(DrawingCanvas 混合模块,v64)。
图片作为对象进当前图层,支持 移动(拖本体)/缩放(拖角等比+边单轴)/裁剪(点图切换后拖角或边)。
核心不变式(v64e 非破坏性裁剪):_bb 恒存**完整原图**(当前缩放级别),显示窗口=
el.cx0/cy0(_bb 内源偏移,默认 0)+ el.w/h(窗口尺寸);渲染=子窗口 blitFrom。
裁剪=纯窗口更新(零像素拷贝,反向拖动自动恢复被隐藏的原图内容);
缩放=重采样整个 _bb 并按同因子缩放窗口;移动=仅 x/y。
持久化:_bb 是下划线字段不序列化,像素经 writePNG 存 drawingboard/images/ 副本(el.src,
内容=完整原图),工程保存时刷新、加载时按 src 原生尺寸重载;每次缩放提交后重写副本。
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local const = require("drawingpad.const")
local L = require("drawingpad.i18n")
local components = require("drawingpad.components")

local M = {}

-- 读 PNG IHDR 宽高(文件头 17-24 字节大端);返回 w, h 或 nil(非 PNG/读失败)。
-- 导入前内存护栏:renderImageFile 会先全尺寸解码再缩放,超大图直接拒绝
local function pngSize(path)
    local ok, w, h = pcall(function()
        local f = io.open(path, "rb")
        if not f then
            return nil
        end
        local head = f:read(24)
        f:close()
        if not head or #head < 24 then
            return nil
        end
        local sig = string.char(137, 80, 78, 71, 13, 10, 26, 10)
        if head:sub(1, 8) ~= sig or head:sub(13, 16) ~= "IHDR" then
            return nil
        end
        local b = { head:byte(17, 24) }
        return b[1] * 16777216 + b[2] * 65536 + b[3] * 256 + b[4],
            b[5] * 16777216 + b[6] * 65536 + b[7] * 256 + b[8]
    end)
    if ok then
        return w, h
    end
    return nil
end
M._pngSize = function(_, path) -- 测试直调(方法形式,self 占位)
    return pngSize(path)
end

-- 加载 PNG → BB8 灰度 bb(默认超画布适配缩小保纵横比;给 tw/th 则按显式目标
-- 尺寸渲染);返回 bb 或 nil, err
function M:_loadImageBB(path, tw, th)
    local w, h = pngSize(path)
    if not w then
        return nil, "not_png"
    end
    if w > const.IMAGE_MAX_DIM or h > const.IMAGE_MAX_DIM then
        return nil, "too_large"
    end
    local dw, dh
    if tw and th then
        -- v65:显式目标(工程重载按 cw/sfx 重建 pristine,与导入时同分辨率)
        dw, dh = math.max(1, tw), math.max(1, th)
    else
        local fit = math.min(const.IMAGE_FIT_RATIO * self.canvas_w / w,
            const.IMAGE_FIT_RATIO * self.canvas_h / h, 1)
        dw = math.max(1, math.floor(w * fit + 0.5))
        dh = math.max(1, math.floor(h * fit + 0.5))
    end
    -- 传目标尺寸让 mupdf 解码内部缩放并立刻 drop 原 pixmap(峰值内存护栏)
    local img = RenderImage:renderImageFile(path, false, dw, dh)
    if not img then
        return nil, "load_failed"
    end
    local iw, ih = img:getWidth(), img:getHeight()
    local bb = Blitbuffer.new(iw, ih, Blitbuffer.TYPE_BB8)
    bb:blitFrom(img, 0, 0, 0, 0, iw, ih) -- 跨类型自动 Rec.601 转灰
    img:free()
    return bb
end

-- v65c:放大超出基准位图(pristine)分辨率时,用直链的原文件按目标尺寸重渲染
-- pristine——放大吃到文件真实细节而非插值变软;旋转路径的最近邻采样同样受益
-- (采样基准分辨率高了,块状感显著减轻)。base 尺寸(cw/ch)语义不变,累计因子
-- 重定基(sfx=base/pristine)。只升不降:目标不超过现有分辨率(含缩小)沿用旧
-- pristine;且设 10% 滞后,微调不触发整档重解码。失败只记日志沿用旧 pristine。
-- ⚠️不 free 旧 pristine:undo 快照的克隆共享其引用,交给 GC 回收
function M:_upgradeImagePristine(el, need_w, need_h)
    if not (el._orig and el.src) then
        return
    end
    local ow, oh = el._orig:getWidth(), el._orig:getHeight()
    local tw = math.min(math.floor(need_w + 0.5), const.IMAGE_MAX_DIM)
    local th = math.min(math.floor(need_h + 0.5), const.IMAGE_MAX_DIM)
    if tw <= ow * 1.1 and th <= oh * 1.1 then
        return -- 未显著超出(或缩小):免整档解码
    end
    local bb, err = self:_loadImageBB(el.src, math.max(tw, ow), math.max(th, oh))
    if not bb then
        self:_log("pristine upgrade failed", el.src, tostring(err))
        return
    end
    el._sfx = (el._sfx or 1) * ow / bb:getWidth()
    el._sfy = (el._sfy or 1) * oh / bb:getHeight()
    el._orig = bb
    self:_log("pristine upgraded", bb:getWidth() .. "x" .. bb:getHeight())
end

-- 图片像素副本目录(drawingboard/images/)
local function imagesDir()
    local lfs = require("libs/libkoreader-lfs")
    local base = DataStorage:getDataDir() .. "/drawingboard"
    if lfs.attributes(base, "mode") ~= "directory" then
        pcall(lfs.mkdir, base)
    end
    local dir = base .. "/images"
    if lfs.attributes(dir, "mode") ~= "directory" then
        pcall(lfs.mkdir, dir)
    end
    return dir
end

-- 把 el._bb 写到像素副本文件(v65:仅保存时对"不可从 src+元数据重建"的元素
-- 调用——旧格式旋转图/烧平后,导入与变换不再触发)。写规则沿 v64w:
-- - `el._persisted_bb` 记录已写入 src 的 bb 对象——像素没变直接跳过;
-- - bb 变了**分配新文件**、绝不复用旧 src:复制出的副本共享 src,
--   各自变换后若仍原位覆盖会互相清掉像素——重开工程时像素与 rot/cx0 不匹配,
--   旋转角度看似"复位"(用户实证);旧文件留给引用它的其他副本与旧工程
-- 失败只记日志:元素仍可编辑,但工程重开时该图丢失像素(渲染跳过 _bb=nil)
function M:_persistImage(el)
    if not (el and el._bb and el._bb.writePNG) then
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    if el.src and el._persisted_bb == el._bb
        and lfs.attributes(el.src, "mode") == "file" then
        return -- 像素未变,已持久化
    end
    el.src = nil -- bb 已变:旧 src 可能被其他副本/旧工程引用,分配新文件
    local stem = "img_" .. os.date("%Y%m%d_%H%M%S")
    local path = imagesDir() .. "/" .. stem .. ".png"
    local n = 0
    while lfs.attributes(path, "mode") == "file" do
        n = n + 1
        path = imagesDir() .. "/" .. stem .. "_" .. n .. ".png"
    end
    el.src = path
    el._bb:writePNG(el.src) -- 错误被吞,靠文件 size 校验
    el._persisted_bb = el._bb
    if not lfs.attributes(el.src, "size") then
        self:_log("persist image failed", el.src)
    end
end

-- 导入入口:文件浏览器选 PNG(复用保存文件夹浏览器;不动 save_folder,
-- 记住上次导入目录 import_folder 作为起始位置,下次直达)
function M:_importImage()
    local saved_folder = self.save_folder
    self:_pickSaveFolder(nil, function(name)
        self:_onImagePicked(name, saved_folder)
    end, "%.png$", L.t("Import image: ", "导入图片: "),
        (self.import_folder and self.import_folder ~= "") and self.import_folder or nil)
end

-- 浏览器选中文件回调。契约:commitFile 已把"文件所在目录"写入 save_folder,
-- 名字已按 file_ext 剥后缀(大写 .PNG 剥不掉,这里兼容两种拼法)。
-- 读完目录即恢复快照——导入不改变保存目录(旧版用导入前快照覆盖回写,
-- 把目录信息一起冲掉,路径拼到旧保存目录 → 恒"无法加载图片")
function M:_onImagePicked(name, saved_folder)
    local dir = (self.save_folder ~= "") and self.save_folder
        or (DataStorage:getDataDir() .. "/drawingboard")
    self.import_folder = dir -- 记住导入目录(SETTING_KEYS 持久化,下次浏览器直达)
    self.save_folder = saved_folder
    local fname = name:lower():match("%.png$") and name or (name .. ".png")
    self:_importImageFile(dir .. "/" .. fname)
end

-- 导入图片文件到当前图层:加载→转灰→入层+撤销→居中放置→自动切选择工具并选中
function M:_importImageFile(path)
    local bb, err = self:_loadImageBB(path)
    if not bb then
        -- 带上尝试的路径(与"File not found"同风格),设备上排障直接看路径对不对
        components.showToast(err == "too_large"
            and L.t("Image too large (max 2500px per side).", "图片过大(单边最大 2500px)。") .. "\n" .. path
            or L.t("Failed to load image:", "无法加载图片:") .. "\n" .. path, 4)
        return
    end
    local el = {
        kind = "image",
        x = math.floor((self.canvas_w - bb:getWidth()) / 2),
        y = math.floor((self.canvas_h - bb:getHeight()) / 2),
        w = bb:getWidth(), h = bb:getHeight(),
        -- v64l base 空间窗口模型:cw/ch=图片自身轴尺寸,cx0/cy0+cww/cwh=裁剪窗口
        -- 在 base 空间的原点与尺寸(默认全图);旋转只动 rot/_bb,窗口元数据随图走
        cw = bb:getWidth(), ch = bb:getHeight(),
        cx0 = 0, cy0 = 0, cww = bb:getWidth(), cwh = bb:getHeight(),
    }
    el._bb = bb
    -- v64n:base 原图(导入分辨率,永不旋转)——缩放/旋转恒从它单趟重采样,
    -- 多次变换零插值累积(修"多次缩放后图片变模糊");与 _bb 共享引用,首次
    -- 变换后 _bb 被替换而 _orig 常驻(多一份 BB8 ≈ 单图内存上限 6.25MB)
    el._orig = bb
    el._sfx, el._sfy = 1, 1
    -- v65:src 直链原文件,不再复制进 images/(导入与变换全程零落盘;
    -- 像素与变换状态全在内存,工程保存只写元数据 rot/窗口/sfx/sfy)
    el.src = path
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    UIManager:setDirty(self, "partial", region)
    -- 导入即选中(切选择工具):边界+四角锚点立即可操作(拖角=缩放,点图切裁剪)
    self:_setTool("select")
    self:_setSelected(el)
    self:_log("import image", path, el.w .. "x" .. el.h)
end

-- ============ v64l base 空间窗口模型几何辅助 ============
-- 窗口定义在图片自身坐标系(base):[cx0,cx0+cww)×[cy0,cy0+cwh) ⊂ [0,cw]×[0,ch];
-- _bb 恒为整图旋转位图(=R(rot)·(cw×ch) 的外包,内容居中);显示 AABB=窗口
-- R(rot) 后的外包。旋转只重采样 _bb,窗口元数据不动=旋转后窗口贴原图同一区域

-- 旧工程/异常态防御性补全窗口字段(v64 旧模型:rot=0 时 el.w/h=窗口尺寸,
-- bb=完整原图;rot≠0 时窗口恒为全图)
function M:_normalizeImageWindow(el)
    if not el._bb then
        return
    end
    local bbw, bbh = el._bb:getWidth(), el._bb:getHeight()
    el.cw = el.cw or bbw
    el.ch = el.ch or bbh
    if not el.cww then
        if (el.rot or 0) ~= 0 and (el.cx0 or 0) == 0 and (el.cy0 or 0) == 0 then
            el.cww, el.cwh = el.cw, el.ch
        else
            el.cww, el.cwh = el.w, el.h
        end
    end
    el.cww = math.max(1, math.min(el.cww, el.cw))
    el.cwh = math.max(1, math.min(el.cwh, el.ch))
    el.cx0 = math.max(0, math.min(el.cx0 or 0, el.cw - el.cww))
    el.cy0 = math.max(0, math.min(el.cy0 or 0, el.ch - el.cwh))
end

-- 由窗口+rot 重算显示 AABB(el.w/h/el.x/el.y);ox/oy = base 中心的屏幕位置 O
-- (固定 O = 内容屏幕不动);new_dims 返回 dw,dh 供调用方
local function windowAABB(el, ox, oy)
    local rot = el.rot or 0
    local ac, as = math.abs(math.cos(rot)), math.abs(math.sin(rot))
    local dw = math.max(1, math.floor(el.cww * ac + el.cwh * as + 0.5))
    local dh = math.max(1, math.floor(el.cww * as + el.cwh * ac + 0.5))
    local c, s = math.cos(rot), math.sin(rot)
    -- base 中心 → 窗口中心 的 base 偏移,旋转到屏幕方向
    local wx = (el.cx0 + el.cww / 2) - el.cw / 2
    local wy = (el.cy0 + el.cwh / 2) - el.ch / 2
    local cx = ox + c * wx - s * wy
    local cy = oy + s * wx + c * wy
    el.w, el.h = dw, dh
    el.x = math.floor(cx - dw / 2)
    el.y = math.floor(cy - dh / 2)
    return dw, dh
end

-- base 中心的屏幕位置 O(由当前显示状态反推)
local function imageOrigin(el)
    local rot = el.rot or 0
    local c, s = math.cos(rot), math.sin(rot)
    local wx = (el.cx0 + el.cww / 2) - el.cw / 2
    local wy = (el.cy0 + el.cwh / 2) - el.ch / 2
    return el.x + el.w / 2 - (c * wx - s * wy), el.y + el.h / 2 - (s * wx + c * wy)
end

-- 重建显示缓存 _disp:窗口在 bb 内是倾斜四边形,dest→bb 为纯平移
-- (R(rot)·R(-rot)=I),逐行算四边形 span 后行拷贝;rot=0 无需缓存(渲染快路径
-- 直接子窗 blitFrom)。提交点(裁剪/旋转/缩放/加载)调用
function M:_rebuildImageDisplay(el)
    el._disp = nil
    el._disp_spans = nil
    local rot = el.rot or 0
    if rot == 0 or not el._bb then
        return
    end
    self:_normalizeImageWindow(el)
    local bbw, bbh = el._bb:getWidth(), el._bb:getHeight()
    local dw, dh = el.w, el.h
    if dw < 1 or dh < 1 then
        return
    end
    local disp = Blitbuffer.new(dw, dh, Blitbuffer.TYPE_BB8)
    disp:paintRect(0, 0, dw, dh, Blitbuffer.COLOR_WHITE)
    local ffi = require("ffi")
    local sbase = ffi.cast("uint8_t*", el._bb.data)
    local dbase = ffi.cast("uint8_t*", disp.data)
    local sstride, dstride = el._bb.stride, disp.stride
    local c, s = math.cos(rot), math.sin(rot)
    -- 窗口四角在 disp 坐标(内容居中于 disp)
    local hw, hh = el.cww / 2, el.cwh / 2
    local corners = { { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }
    for i, p in ipairs(corners) do
        corners[i] = { dw / 2 + c * p[1] - s * p[2], dh / 2 + s * p[1] + c * p[2] }
    end
    -- dest→bb 平移量:q = bb 中心 + (screen - O),screen = (el.x+dx, el.y+dy)
    local ox, oy = imageOrigin(el)
    local tx = math.floor(bbw / 2 + el.x - ox)
    local ty = math.floor(bbh / 2 + el.y - oy)
    local spans = {} -- 每行窗口四边形 x 跨度 [x0,x1):渲染只画窗口内像素,
    -- 白角不落画布=旋转图遮挡不超出(倾斜)对象框(v64v)
    for y = 0, dh - 1 do
        -- 凸四边形行 span:每条边在该行的交点 x 取 min/max
        local xs, xe = math.huge, -math.huge
        for i = 1, 4 do
            local p1, p2 = corners[i], corners[i % 4 + 1]
            local y1, y2 = p1[2], p2[2]
            if y1 ~= y2 then
                local lo, hi = math.min(y1, y2), math.max(y1, y2)
                if y >= lo and y < hi then
                    local t = (y - y1) / (y2 - y1)
                    local x = p1[1] + t * (p2[1] - p1[1])
                    xs = math.min(xs, x)
                    xe = math.max(xe, x)
                end
            end
        end
        if xe > xs then
            local x0 = math.max(0, math.floor(xs + 0.5))
            local x1 = math.min(dw, math.ceil(xe - 0.5))
            if x1 > x0 then
                spans[y + 1] = { x0, x1 }
                local sy, sx = y + ty, x0 + tx
                if sy >= 0 and sy < bbh and sx >= 0 and sx + (x1 - x0) <= bbw then
                    ffi.copy(dbase + dstride * y + x0,
                        sbase + sstride * sy + sx, x1 - x0)
                end
            end
        end
    end
    el._disp = disp
    el._disp_spans = spans
end

-- 屏幕点 → base 坐标(逆旋转到图片自身坐标系)
local function screenToBase(el, x, y, ox, oy)
    local rot = el.rot or 0
    local c, s = math.cos(rot), math.sin(rot)
    local dx, dy = x - ox, y - oy
    -- base = base_center + R(-rot)·(screen - O)
    return el.cw / 2 + c * dx + s * dy, el.ch / 2 - s * dx + c * dy
end

-- 按锚点+base 坐标指针算新窗口矩形(x0,y0,x1,y1,base 空间);提交与预览共用
local function cropWindowBase(el, handle, px, py)
    local min_size = 4
    -- 四舍五入而非 floor:屏幕↔base 浮点往返在大画布坐标下有 ~1ulp 噪声,
    -- floor 会把 49.9999 砍成 49(真机大画布实测差一像素)
    px = math.floor(px + 0.5)
    py = math.floor(py + 0.5)
    local x0, y0 = el.cx0, el.cy0
    local x1, y1 = el.cx0 + el.cww, el.cy0 + el.cwh
    if handle == "nw" then
        x0 = math.max(0, math.min(px, x1 - min_size))
        y0 = math.max(0, math.min(py, y1 - min_size))
    elseif handle == "ne" then
        y0 = math.max(0, math.min(py, y1 - min_size))
        x1 = math.min(el.cw, math.max(px, x0 + min_size))
    elseif handle == "se" then
        x1 = math.min(el.cw, math.max(px, x0 + min_size))
        y1 = math.min(el.ch, math.max(py, y0 + min_size))
    elseif handle == "sw" then
        x0 = math.max(0, math.min(px, x1 - min_size))
        y1 = math.min(el.ch, math.max(py, y0 + min_size))
    elseif handle == "n" then
        y0 = math.max(0, math.min(py, y1 - min_size))
    elseif handle == "s" then
        y1 = math.min(el.ch, math.max(py, y0 + min_size))
    elseif handle == "w" then
        x0 = math.max(0, math.min(px, x1 - min_size))
    elseif handle == "e" then
        x1 = math.min(el.cw, math.max(px, x0 + min_size))
    end
    return x0, y0, x1, y1
end

-- 裁剪提交(v64l base 空间):指针屏幕坐标 → base 坐标直接设定窗口角/边,
-- 钳制到 [0,cw]×[0,ch](反向拖=恢复隐藏内容,整图恒在 _bb 永不丢弃);
-- 屏幕锚点 O 固定=可见内容不动;纯元数据更新,零像素拷贝零重采样
function M:_applyImageCrop(el, handle, x, y)
    if not el._bb then
        return
    end
    self:_normalizeImageWindow(el)
    local ox, oy = imageOrigin(el)
    local px, py = screenToBase(el, x, y, ox, oy)
    local x0, y0, x1, y1 = cropWindowBase(el, handle, px, py)
    if x0 == el.cx0 and y0 == el.cy0
        and (x1 - x0) == el.cww and (y1 - y0) == el.cwh then
        return -- 窗口未变
    end
    el.cx0, el.cy0, el.cww, el.cwh = x0, y0, x1 - x0, y1 - y0
    windowAABB(el, ox, oy)
    self:_rebuildImageDisplay(el)
end

-- 裁剪窗口平移(v64s):裁剪模式未命中锚点的拖动——框在屏幕上固定(el.x/y 不动),
-- 窗口相对原图移动(内容在框下滑动,图片跟随手指=窗口反向),零重采样零像素拷贝。
-- 旋转图同样适用:cx0/cy0 逆旋转位移,只重建 _disp
function M:_updateImageCropPan(x, y)
    local pan = self._crop_pan
    local el = self._selected
    if not (pan and el and el.kind == "image" and el._bb) then
        return
    end
    self:_normalizeImageWindow(el)
    local dx, dy = x - pan.x0, y - pan.y0
    local rot = el.rot or 0
    local c, s = math.cos(rot), math.sin(rot)
    -- 图片跟随手指:窗口反向移动(屏幕位移 → base 位移取负)
    el.cx0 = math.max(0, math.min(pan.cx0 - (c * dx + s * dy), el.cw - el.cww))
    el.cy0 = math.max(0, math.min(pan.cy0 - (-s * dx + c * dy), el.ch - el.cwh))
    self:_rebuildImageDisplay(el)
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    UIManager:setDirty(self, "partial", region)
end

-- 裁剪拖动预览四角(v64l):与提交同一 base 数学,返回新窗口 R(rot) 后的
-- 4 屏幕角 + 外包框;rot=0 时退化为轴对齐(调用方按角画闭合线框)
function M:_imageCropPreviewQuad(el, handle, x, y)
    self:_normalizeImageWindow(el)
    local ox, oy = imageOrigin(el)
    local px, py = screenToBase(el, x, y, ox, oy)
    local x0, y0, x1, y1 = cropWindowBase(el, handle, px, py)
    local rot = el.rot or 0
    local c, s = math.cos(rot), math.sin(rot)
    -- 新窗口中心(base) → 屏幕
    local wx = (x0 + x1) / 2 - el.cw / 2
    local wy = (y0 + y1) / 2 - el.ch / 2
    local ccx, ccy = ox + c * wx - s * wy, oy + s * wx + c * wy
    local hw, hh = (x1 - x0) / 2, (y1 - y0) / 2
    local pts = { { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i, p in ipairs(pts) do
        local sx = ccx + c * p[1] - s * p[2]
        local sy = ccy + s * p[1] + c * p[2]
        pts[i] = { x = sx, y = sy }
        minx = math.min(minx, sx); maxx = math.max(maxx, sx)
        miny = math.min(miny, sy); maxy = math.max(maxy, sy)
    end
    return pts, { x0 = minx, y0 = miny, x1 = maxx, y1 = maxy }
end

-- 缩放提交(v64n):重采样并按同因子缩放 base 窗口字段(窗口相对原图位置不变)。
-- 恒从 _orig(base 原图)单趟重采样——多次缩放零插值累积(修"越缩越模糊")。
-- rot=0 走 scaleBlitBuffer(C 插值);rot≠0 走 base 缩放核心(逐像素复合矩阵,
-- 等比绕对角/中心、单轴沿图片自身轴);无 _orig(工程重载/烧平后)退化当前 bb。
-- free_orig=false——旧 bb 由 undo 快照引用,交给 GC
function M:_applyImageScale(el, nb, handle, x, y)
    if not el._bb then
        return
    end
    self:_normalizeImageWindow(el)
    local nw = math.max(1, math.floor(nb.x1 - nb.x0 + 0.5))
    local nh = math.max(1, math.floor(nb.y1 - nb.y0 + 0.5))
    if nw == el.w and nh == el.h then
        el.x, el.y = math.floor(nb.x0), math.floor(nb.y0)
        return
    end
    local fx = nw / math.max(1, el.w)
    local fy = nh / math.max(1, el.h)
    -- 旋转图 + 原图在手:全部走 base 缩放核心(逐像素,零累计模糊)
    if (el.rot or 0) ~= 0 and el._orig then
        if handle == "n" or handle == "s" or handle == "e" or handle == "w" then
            -- 边锚:沿图片自身轴(指针→因子,对侧窗口边为锚)
            self:_applyImageBaseScale(el, handle, x, y)
        elseif handle then
            -- 角锚等比(v64o):指针沿对角线投影→因子,锚=对侧窗口角。
            -- ⚠️不可用 AABB nb 因子——倾斜图拖的是可见窗口角,AABB 角在别处,
            -- 指针位移换算出的 f 全错(30px 拖动 f≈1.007,多轮累积=内容偏移)
            local ox, oy = imageOrigin(el)
            local px, py = screenToBase(el, x, y, ox, oy)
            local x0, y0 = el.cx0, el.cy0
            local x1, y1 = el.cx0 + el.cww, el.cy0 + el.cwh
            local cx, cy, ax, ay
            if handle == "se" then
                cx, cy, ax, ay = x1, y1, x0, y0
            elseif handle == "nw" then
                cx, cy, ax, ay = x0, y0, x1, y1
            elseif handle == "ne" then
                cx, cy, ax, ay = x1, y0, x0, y1
            else
                cx, cy, ax, ay = x0, y1, x1, y0
            end
            local dxg, dyg = cx - ax, cy - ay
            local f = ((px - ax) * dxg + (py - ay) * dyg)
                / math.max(1, dxg * dxg + dyg * dyg)
            self:_applyImageBaseScaleF(el, f, f, ax, ay)
        else
            -- 无 handle(双指等兜底):绕窗口中心等比
            self:_applyImageBaseScaleF(el, (fx + fy) / 2, (fx + fy) / 2,
                el.cx0 + el.cww / 2, el.cy0 + el.cwh / 2)
        end
        return
    end
    -- 旋转图无原图:边锚=当前 bb 的 base 缩放;单轴无 handle=烧平兜底
    if (el.rot or 0) ~= 0 and handle
        and (handle == "n" or handle == "s" or handle == "e" or handle == "w") then
        self:_applyImageBaseScale(el, handle, x, y)
        return
    end
    if (el.rot or 0) ~= 0
        and (math.abs(nw - el.w) > 1) ~= (math.abs(nh - el.h) > 1) then
        -- 烧平(显示内容=新原图;_orig 语义随之作废)
        if not el._disp then
            self:_rebuildImageDisplay(el)
        end
        if el._disp then
            local baked = Blitbuffer.new(el.w, el.h, Blitbuffer.TYPE_BB8)
            baked:blitFrom(el._disp, 0, 0, 0, 0, el.w, el.h)
            el._bb = baked
        end
        el.rot = 0
        el.cw, el.ch = el.w, el.h
        el.cx0, el.cy0 = 0, 0
        el.cww, el.cwh = el.w, el.h
        el._disp = nil
        el._orig = nil
        el._sfx, el._sfy = 1, 1
    end
    -- 重采样源:优先 base 原图(单趟,零累计);窗口字段仍按本次 fx/fy 缩放
    -- 放大超基准分辨率先升级 pristine(v65c:从原文件重渲染)
    self:_upgradeImagePristine(el, el.cw * fx, el.ch * fy)
    local sfx = (el._sfx or 1) * fx
    local sfy = (el._sfy or 1) * fy
    local src = el._orig or el._bb
    local nbw, nbh
    if el._orig then
        local ow0, oh0 = el._orig:getWidth(), el._orig:getHeight()
        nbw = math.max(nw, math.floor(ow0 * sfx + 0.5))
        nbh = math.max(nh, math.floor(oh0 * sfy + 0.5))
    else
        local bbw, bbh = el._bb:getWidth(), el._bb:getHeight()
        nbw = math.max(nw, math.floor(bbw * fx + 0.5))
        nbh = math.max(nh, math.floor(bbh * fy + 0.5))
    end
    local scaled = RenderImage:scaleBlitBuffer(src, nbw, nbh, false)
    if not scaled then
        return
    end
    if scaled ~= el._bb then
        el._bb = scaled
    end
    if el._orig then
        el._sfx, el._sfy = sfx, sfy
    end
    -- base 尺寸与窗口同因子缩放(窗口相对原图位置不变)。
    -- ⚠️保持浮点不取整:每轮 floor 的取整误差以绝对像素在 base 坐标累积,
    -- 多轮缩放后窗口相对内容漂移(裁剪后反复缩放偏移实证);取整只在渲染 blit 时做
    el.cw = math.max(1, el.cw * fx)
    el.ch = math.max(1, el.ch * fy)
    el.cww = math.max(1, math.min(el.cww * fx, el.cw))
    el.cwh = math.max(1, math.min(el.cwh * fy, el.ch))
    el.cx0 = math.max(0, math.min(el.cx0 * fx, el.cw - el.cww))
    el.cy0 = math.max(0, math.min(el.cy0 * fy, el.ch - el.cwh))
    el.x, el.y = math.floor(nb.x0), math.floor(nb.y0)
    el.w, el.h = nw, nh
    self:_rebuildImageDisplay(el)
end

-- 旋转图边锚单轴拉伸入口(v64m):指针→因子+对侧窗口边锚,转核心
function M:_applyImageBaseScale(el, handle, x, y)
    local ox, oy = imageOrigin(el)
    local px, py = screenToBase(el, x, y, ox, oy)
    -- 锚=对侧窗口边(base 绝对坐标);因子=指针到锚 / 窗口边到锚
    local fx, fy = 1, 1
    local ax, ay = 0, 0
    if handle == "e" then
        ax = el.cx0
        fx = (px - ax) / math.max(1, el.cww)
    elseif handle == "w" then
        ax = el.cx0 + el.cww
        fx = (ax - px) / math.max(1, el.cww)
    elseif handle == "n" then
        ay = el.cy0 + el.cwh
        fy = (ay - py) / math.max(1, el.cwh)
    elseif handle == "s" then
        ay = el.cy0
        fy = (py - ay) / math.max(1, el.cwh)
    else
        return
    end
    self:_applyImageBaseScaleF(el, fx, fy, ax, ay)
end

-- base 缩放核心(v64n):base 空间等比/双轴 (fx,fy) 缩放,锚点 A(base 绝对,
-- 对侧窗口角/边中点/中心)屏幕位置固定——显示框角度不变。
-- ⚠️字段一律绕图片原点缩放(cx0·f 等,窗口相对位置不变):base 坐标系随图片
-- 本身缩放,锚点若参与字段缩放会把窗口推出 [0,cw]×[0,ch](v64n 实证 NE 漂 23px,
-- 随后被 normalize 钳回=锚点语义破坏);锚点只进屏幕定位:
--   O_new = O + R(rot)·(a(1-f)),a = A − 旧 base 中心
--   恒等式:锚屏幕 = O_new + R·(A_new − 新中心) = O + R·(a(1-f) + f·a) = O + R·a ✓
-- 采样:dest → v → p' = R(-rot)v(新 base 中心相对) → 旧 base 绝对 = (p'+新半宽)/f
--      → 有 _orig 直取 pristine 像素(=旧绝对/sf,零累计模糊);无 _orig 退旧 bb
function M:_applyImageBaseScaleF(el, fx, fy, ax, ay)
    fx = math.max(8 / math.max(1, el.cw), math.min(4, fx))
    fy = math.max(8 / math.max(1, el.ch), math.min(4, fy))
    if math.abs(fx - 1) < 0.01 and math.abs(fy - 1) < 0.01 then
        return
    end
    local ox, oy = imageOrigin(el)
    local rot = el.rot or 0
    local c, s = math.cos(rot), math.sin(rot)
    local cw, ch = el.cw, el.ch
    local cw2, ch2 = cw * fx, ch * fy
    -- a = 锚点 − 旧 base 中心(用于 O_new;字段不参与)
    local aax, aay = ax - cw / 2, ay - ch / 2
    local acN, asN = math.abs(c), math.abs(s)
    local nbw = math.max(1, math.floor(cw2 * acN + ch2 * asN + 0.5))
    local nbh = math.max(1, math.floor(cw2 * asN + ch2 * acN + 0.5))
    local nbb = Blitbuffer.new(nbw, nbh, Blitbuffer.TYPE_BB8)
    nbb:paintRect(0, 0, nbw, nbh, Blitbuffer.COLOR_WHITE)
    local ffi = require("ffi")
    -- 放大超基准分辨率先升级 pristine(v65c):最近邻采样基准高了,块状感大减
    self:_upgradeImagePristine(el, cw2, ch2)
    local sfx, sfy = el._sfx or 1, el._sfy or 1
    local src, bbw, bbh
    if el._orig then
        src = el._orig
        bbw, bbh = src:getWidth(), src:getHeight()
    else
        src = el._bb
        bbw, bbh = src:getWidth(), src:getHeight()
    end
    local sbase = ffi.cast("uint8_t*", src.data)
    local dbase = ffi.cast("uint8_t*", nbb.data)
    local sstride, dstride = src.stride, nbb.stride
    local dcx, dcy = nbw / 2, nbh / 2
    local invx, invy = 1 / fx, 1 / fy
    local half_new_x, half_new_y = cw2 / 2, ch2 / 2
    for dy = 0, nbh - 1 do
        local drow = dbase + dstride * dy
        local vy = dy - dcy
        for dx = 0, nbw - 1 do
            local vx = dx - dcx
            -- v → 新 base 中心相对 p' = R(-rot)·v → 新 base 绝对 = p'+新半宽
            -- → 旧 base 绝对 = 新绝对/f
            local ppx = (c * vx + s * vy + half_new_x) * invx
            local ppy = (-s * vx + c * vy + half_new_y) * invy
            local sx, sy
            if el._orig then
                -- 旧 base 绝对 → pristine 像素(=base 坐标 / 累计因子)
                sx = math.floor(ppx / sfx)
                sy = math.floor(ppy / sfy)
                if sx >= 0 and sx < bbw and sy >= 0 and sy < bbh then
                    drow[dx] = sbase[sstride * sy + sx]
                end
            else
                -- 旧 base 绝对 → 旧 bb 中心相对 → bb 像素
                local qx = ppx - cw / 2
                local qy = ppy - ch / 2
                sx = math.floor(bbw / 2 + c * qx - s * qy)
                sy = math.floor(bbh / 2 + s * qx + c * qy)
                if sx >= 0 and sx < bbw and sy >= 0 and sy < bbh then
                    drow[dx] = sbase[sstride * sy + sx]
                end
            end
        end
    end
    el._bb = nbb
    -- 字段绕原点缩放(窗口相对位置不变;钳制只防浮点噪声)
    el.cw, el.ch = cw2, ch2
    el.cx0 = math.max(0, math.min(el.cx0 * fx, cw2 - math.max(1, el.cww * fx)))
    el.cy0 = math.max(0, math.min(el.cy0 * fy, ch2 - math.max(1, el.cwh * fy)))
    el.cww = math.max(1, el.cww * fx)
    el.cwh = math.max(1, el.cwh * fy)
    -- ⚠️累计因子同步:v64n 首版漏更——base 已放大 fx,下次旋转按旧 sf 从
    -- pristine 采样=内容偏移(裁剪→缩放→旋转偏移实证)
    if el._orig then
        el._sfx, el._sfy = sfx * fx, sfy * fy
    end
    -- O_new = O + R(rot)·(a(1-f)),锚屏幕不动
    local nox = ox + c * aax * (1 - fx) - s * aay * (1 - fy)
    local noy = oy + s * aax * (1 - fx) + c * aay * (1 - fy)
    windowAABB(el, nox, noy)
    self:_rebuildImageDisplay(el)
end

-- 共享:给定双轴因子+锚点(base 绝对坐标),返回缩放后窗口 R(rot) 的 4 屏幕角
-- 与外包框(与 _applyImageBaseScaleF 提交同一数学:字段绕原点缩放,
-- O_new = O + R·(a(1-f)),锚屏幕恒等)
local function baseScaleQuad(el, fx, fy, ax, ay)
    local rot = el.rot or 0
    local c, s = math.cos(rot), math.sin(rot)
    local cw2, ch2 = el.cw * fx, el.ch * fy
    local aax, aay = ax - el.cw / 2, ay - el.ch / 2
    local ox, oy = imageOrigin(el)
    local nox = ox + c * aax * (1 - fx) - s * aay * (1 - fy)
    local noy = oy + s * aax * (1 - fx) + c * aay * (1 - fy)
    -- 新窗口矩形(base)四角 → 屏幕
    local wx0 = el.cx0 * fx
    local wy0 = el.cy0 * fy
    local wx1 = wx0 + el.cww * fx
    local wy1 = wy0 + el.cwh * fy
    local pts = { { wx0, wy0 }, { wx1, wy0 }, { wx1, wy1 }, { wx0, wy1 } }
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i, p in ipairs(pts) do
        local bx, by = p[1] - cw2 / 2, p[2] - ch2 / 2
        local sx = nox + c * bx - s * by
        local sy = noy + s * bx + c * by
        pts[i] = { x = sx, y = sy }
        minx = math.min(minx, sx); maxx = math.max(maxx, sx)
        miny = math.min(miny, sy); maxy = math.max(maxy, sy)
    end
    return pts, { x0 = minx, y0 = miny, x1 = maxx, y1 = maxy }
end

-- 旋转图边锚拉伸预览四角(v64m):与提交同一 base 因子数学,返回缩放后窗口
-- R(rot) 的 4 屏幕角与外包框(画闭合线框;与 _flushImageFramePreview 共用)
function M:_imageScalePreviewQuad(el, handle, x, y)
    self:_normalizeImageWindow(el)
    local ox, oy = imageOrigin(el)
    local px, py = screenToBase(el, x, y, ox, oy)
    local fx, fy = 1, 1
    local ax, ay = 0, 0
    if handle == "e" then
        ax = el.cx0
        fx = (px - ax) / math.max(1, el.cww)
    elseif handle == "w" then
        ax = el.cx0 + el.cww
        fx = (ax - px) / math.max(1, el.cww)
    elseif handle == "n" then
        ay = el.cy0 + el.cwh
        fy = (ay - py) / math.max(1, el.cwh)
    elseif handle == "s" then
        ay = el.cy0
        fy = (py - ay) / math.max(1, el.cwh)
    end
    fx = math.max(8 / math.max(1, el.cw), math.min(4, fx))
    fy = math.max(8 / math.max(1, el.ch), math.min(4, fy))
    return baseScaleQuad(el, fx, fy, ax, ay)
end

-- 旋转图角锚等比预览四角(v64o):指针沿对角线投影→因子(与提交同一数学),
-- 锚=对侧窗口角,窗口四边形随图片角度——预览框贴倾斜内容
function M:_imageScaleCornerQuad(el, handle, x, y)
    self:_normalizeImageWindow(el)
    local ox, oy = imageOrigin(el)
    local px, py = screenToBase(el, x, y, ox, oy)
    local x0, y0 = el.cx0, el.cy0
    local x1, y1 = el.cx0 + el.cww, el.cy0 + el.cwh
    local cx, cy, ax, ay
    if handle == "se" then
        cx, cy, ax, ay = x1, y1, x0, y0
    elseif handle == "nw" then
        cx, cy, ax, ay = x0, y0, x1, y1
    elseif handle == "ne" then
        cx, cy, ax, ay = x1, y0, x0, y1
    else
        cx, cy, ax, ay = x0, y1, x1, y0
    end
    local dxg, dyg = cx - ax, cy - ay
    local f = ((px - ax) * dxg + (py - ay) * dyg)
        / math.max(1, dxg * dxg + dyg * dyg)
    return baseScaleQuad(el, f, f, ax, ay)
end

-- 工程加载:按 el.src 重载像素。
-- v65 新格式(src=原图直链+公共 sfx/sfy 元数据):按 (cw/sfx, ch/sfy) 目标尺寸
-- 渲染原图 → _orig(pristine),再按 rot 重建 _bb(与在线变换同一采样数学,
-- 见 _rebuildImageBBFromState);此后导入/变换/保存全程零落盘。
-- 旧格式(无 sfx,src=状态位图):整图载入为 _bb;rot=0 时无损升级为 pristine
-- (bb 即未旋转 base 图)→ 下次保存起也不再落盘;rot≠0 的旧元素 bb 不可从
-- src 重建,保存时仍写像素副本(唯一残余落盘路径)
-- 失败保留元素但渲染跳过(_bb=nil)
function M:_reloadImageBB(el)
    if el._bb then
        return true
    end
    if not el.src then
        return false
    end
    local sfx = tonumber(el.sfx)
    local sfy = tonumber(el.sfy)
    local newfmt = sfx and sfy and sfx > 0 and sfy > 0
    local ok, bb, err
    if newfmt then
        local tw = el.cw and math.max(1, math.floor(el.cw / sfx + 0.5))
        local th = el.ch and math.max(1, math.floor(el.ch / sfy + 0.5))
        ok, bb, err = pcall(self._loadImageBB, self, el.src, tw, th)
        if ok and not bb then -- _loadImageBB 失败返回 (nil, err)
            self:_log("reload image failed", el.src, tostring(err))
            return false
        end
    else
        ok, bb = pcall(function()
            return RenderImage:renderImageFile(el.src, false)
        end)
        if ok and bb then
            local iw, ih = bb:getWidth(), bb:getHeight()
            local t_ok, t = pcall(bb.getType, bb)
            if t_ok and t ~= Blitbuffer.TYPE_BB8 then
                local b8 = Blitbuffer.new(iw, ih, Blitbuffer.TYPE_BB8)
                b8:blitFrom(bb, 0, 0, 0, 0, iw, ih)
                if bb.free then
                    bb:free()
                end
                bb = b8
            end
        end
    end
    if ok and bb then
        el._bb = bb
        -- 窗口字段防御性补全+钳制(先于重建:重建依赖 cw/ch)
        self:_normalizeImageWindow(el)
        el.sfx, el.sfy = nil, nil
        if newfmt then
            el._orig = bb
            el._sfx, el._sfy = sfx, sfy
            self:_rebuildImageBBFromState(el)
        elseif (el.rot or 0) == 0 then
            el._orig = bb
            el._sfx, el._sfy = 1, 1
        else
            el._orig = nil
            el._sfx, el._sfy = 1, 1
            -- 旧格式 bb 保存时仍需落盘:记录已持久化对象,未变前跳过重写
            el._persisted_bb = el._bb
        end
        self:_rebuildImageDisplay(el)
        return true
    end
    self:_log("reload image failed", el.src)
    return false
end

-- v65:从 _orig(原图)+_sfx/_sfy+rot 重建 _bb(工程重载)。采样数学与
-- _applyImageRotate 的 _orig 分支完全一致(rot_old=0:pristine 未旋转),
-- 保证"存盘→重开"与在线变换像素一致
function M:_rebuildImageBBFromState(el)
    local ffi = require("ffi")
    local src = el._orig
    local sfx, sfy = el._sfx or 1, el._sfy or 1
    local rot = el.rot or 0
    local pw, ph = src:getWidth(), src:getHeight()
    local cw, ch = el.cw, el.ch
    local ac, as = math.abs(math.cos(rot)), math.abs(math.sin(rot))
    local nw = math.max(1, math.floor(cw * ac + ch * as + 0.5))
    local nh = math.max(1, math.floor(cw * as + ch * ac + 0.5))
    local bb = Blitbuffer.new(nw, nh, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, nw, nh, Blitbuffer.COLOR_WHITE)
    local sbase = ffi.cast("uint8_t*", src.data)
    local dbase = ffi.cast("uint8_t*", bb.data)
    local sstride, dstride = src.stride, bb.stride
    local c, s = math.cos(rot), math.sin(rot)
    local dcx, dcy = nw / 2, nh / 2
    for dy = 0, nh - 1 do
        local drow = dbase + dstride * dy
        local ry = dy - dcy
        for dx = 0, nw - 1 do
            local rx = dx - dcx
            -- dest → base 中心相对 p = R(-rot)·v → pristine 像素((p+半宽)/sf)
            local px = c * rx + s * ry
            local py = -s * rx + c * ry
            local sx = math.floor((cw / 2 + px) / sfx)
            local sy = math.floor((ch / 2 + py) / sfy)
            if sx >= 0 and sx < pw and sy >= 0 and sy < ph then
                drow[dx] = sbase[sstride * sy + sx]
            end
        end
    end
    el._bb = bb
end

-- 旋转提交(v64l/v64n):整图重采样(基准方向直达,白角不累积)。窗口元数据
-- (base 空间)原样保留——旋转后窗口贴原图同一区域;绕窗口显示中心旋转。
-- v64n:有 _orig 时直接从 base 原图单趟采样(p=base 中心相对→pristine=(p+半宽)/sf),
-- 多次旋转零最近邻累积;无 _orig(重载/烧平后)退化旧 bb 的 rot_old 复合映射。
-- 逐像素逆映射 + stride 指针直访(v63b 惯例)。不变式:bb = R(el.rot)·(el.cw×el.ch) 正包围
function M:_applyImageRotate(el, angle)
    if not el._bb or math.abs(angle) < 0.01 then
        return
    end
    self:_normalizeImageWindow(el)
    local ffi = require("ffi")
    local src, sfx, sfy
    if el._orig then
        src = el._orig
        sfx, sfy = el._sfx or 1, el._sfy or 1
    else
        src = el._bb
        sfx, sfy = 1, 1
    end
    local bbw, bbh = src:getWidth(), src:getHeight()
    local rot_old = el.rot or 0
    local rot_new = rot_old + angle
    local cw, ch = el.cw, el.ch
    local acN, asN = math.abs(math.cos(rot_new)), math.abs(math.sin(rot_new))
    local nw = math.max(1, math.floor(cw * acN + ch * asN + 0.5))
    local nh = math.max(1, math.floor(cw * asN + ch * acN + 0.5))
    local nbb = Blitbuffer.new(nw, nh, Blitbuffer.TYPE_BB8)
    nbb:paintRect(0, 0, nw, nh, Blitbuffer.COLOR_WHITE)
    local sbase = ffi.cast("uint8_t*", src.data)
    local dbase = ffi.cast("uint8_t*", nbb.data)
    local sstride, dstride = src.stride, nbb.stride
    local cN, sN = math.cos(rot_new), math.sin(rot_new)
    local cO, sO = math.cos(rot_old), math.sin(rot_old)
    local dcx, dcy = nw / 2, nh / 2
    for dy = 0, nh - 1 do
        local drow = dbase + dstride * dy
        local ry = dy - dcy
        for dx = 0, nw - 1 do
            local rx = dx - dcx
            -- dest → 基准中心相对坐标 p = R(-rot_new)·(dest - 新中心)
            local px = cN * rx + sN * ry
            local py = -sN * rx + cN * ry
            local sx, sy
            if el._orig then
                -- p → pristine 像素((p+旧半宽)/sf,单趟零累计)
                sx = math.floor((cw / 2 + px) / sfx)
                sy = math.floor((ch / 2 + py) / sfy)
            else
                -- p → 旧 bb:内容中心(bb 中心) + R(rot_old)·p
                -- ⚠️p 已是中心相对坐标,不能再减半幅(两套约定混用=逐轮错位,v64k 实证)
                sx = math.floor(bbw / 2 + cO * px - sO * py)
                sy = math.floor(bbh / 2 + sO * px + cO * py)
            end
            if sx >= 0 and sx < bbw and sy >= 0 and sy < bbh then
                drow[dx] = sbase[sstride * sy + sx]
            end
        end
    end
    -- 先算旧 O(用旧 rot/el.x/y),再绕窗口屏幕中心更新
    local ox, oy = imageOrigin(el)
    local wx = (el.cx0 + el.cww / 2) - el.cw / 2
    local wy = (el.cy0 + el.cwh / 2) - el.ch / 2
    local ccx = ox + cO * wx - sO * wy
    local ccy = oy + sO * wx + cO * wy
    el._bb = nbb
    el.rot = rot_new
    -- O_new:窗口屏幕中心 (ccx,ccy) 不动
    windowAABB(el, ccx - (cN * wx - sN * wy), ccy - (sN * wx + cN * wy))
    self:_rebuildImageDisplay(el)
end

-- 旋转预览几何:返回窗口矩形转 (el.rot+Δ) 后的 4 角(画线框)与外包框
-- (预览线框与 _flushImageFramePreview 刷新区域共用同一数学;窗口尺寸缺省
-- 用显示尺寸,与提交的 base 窗口一致)
function M:_imageRotatePreview(tr, pos)
    local el = self._selected
    local sb = tr.bbox
    local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
    local d = math.atan2(pos.y - cy, pos.x - cx) - math.atan2(tr.y0 - cy, tr.x0 - cx)
    local total = (el.rot or 0) + d
    local hw = (el.cww or el.w) / 2
    local hh = (el.cwh or el.h) / 2
    local cos, sin = math.cos(total), math.sin(total)
    local pts = { { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i, p in ipairs(pts) do
        local x = cx + p[1] * cos - p[2] * sin
        local y = cy + p[1] * sin + p[2] * cos
        pts[i] = { x = x, y = y }
        minx = math.min(minx, x)
        maxx = math.max(maxx, x)
        miny = math.min(miny, y)
        maxy = math.max(maxy, y)
    end
    return pts, { x0 = minx, y0 = miny, x1 = maxx, y1 = maxy }
end

-- 图片拖角(缩放/裁剪)线框预览:pan 逐事件只记位置,按预览节流间隔刷新;
-- 目标框/原窗口框画在 paintTo(不重采样不建克隆,真机不卡)。
-- 复用 _drag_preview_repaint_fn 定时器与 _drag_preview_region 累积区
-- (_cancelDragPreview/_finishTransform 原有清理路径自动盖住)
function M:_scheduleImageFramePreview(x, y)
    self._drag_preview_pos = { x = x, y = y }
    if not self._drag_preview_repaint_pending then
        self._drag_preview_repaint_pending = true
        local fn = function()
            self:_flushImageFramePreview()
        end
        self._drag_preview_repaint_fn = fn
        UIManager:scheduleIn(const.DRAG_PREVIEW_REFRESH_INTERVAL, fn)
    end
end

-- 图片变形目标窗口(v64c):角锚(nw/ne/se/sw)= Office 语义等比缩放——对角固定,
-- 两轴同因子(f=两轴比率均值,双指/角拖主方向主导);边锚(n/e/s/w)= 单轴拉伸。
-- 角等比必须走这里(通用 _transformBBox 是自由拉伸),预览与提交共用同一数学
function M:_imageTransformBBox(handle, sb, x, y)
    if handle == "n" or handle == "s" or handle == "w" or handle == "e" then
        return self:_transformBBox(handle, sb, x, y)
    end
    local nb = self:_transformBBox(handle, sb, x, y)
    local ow, oh = sb.x1 - sb.x0, sb.y1 - sb.y0
    if ow < 1 or oh < 1 then
        return nb
    end
    local f = (math.abs(nb.x1 - nb.x0) / ow + math.abs(nb.y1 - nb.y0) / oh) / 2
    -- 对角固定重建等比窗口(最小 8px)
    local nw = math.max(8, math.floor(ow * f + 0.5))
    local nh = math.max(8, math.floor(oh * f + 0.5))
    if handle == "se" then
        return { x0 = sb.x0, y0 = sb.y0, x1 = sb.x0 + nw, y1 = sb.y0 + nh }
    elseif handle == "nw" then
        return { x0 = sb.x1 - nw, y0 = sb.y1 - nh, x1 = sb.x1, y1 = sb.y1 }
    elseif handle == "ne" then
        return { x0 = sb.x0, y0 = sb.y1 - nh, x1 = sb.x0 + nw, y1 = sb.y1 }
    else -- sw
        return { x0 = sb.x1 - nw, y0 = sb.y0, x1 = sb.x1, y1 = sb.y0 + nh }
    end
end

-- 双指捏合/张开缩放图片(v64c):ratio = 松开时双指间距(span)/按下间距(start_span),
-- 官方 imageviewer 同款一次性事件(收笔才发)。绕图片中心等比缩放,一条 transform 撤销;
-- 手势中心落在图片上时自动选中(不必先点选)
function M:_pinchScaleImage(ges)
    if not (ges and ges.start_span and ges.span and ges.start_span > 0) then
        return
    end
    local ratio = ges.span / ges.start_span
    if math.abs(ratio - 1) < 0.05 then
        return -- 间距几乎没变
    end
    local el = self._selected
    if self.tool ~= "select" or not el or el.kind ~= "image" then
        if ges.pos then
            local px, py = self:_toCanvas(ges.pos.x, ges.pos.y)
            local picked = px and self:_pickElementAt(px, py)
            if picked and picked.kind == "image" then
                self:_setTool("select")
                self:_setSelected(picked)
                el = picked
            end
        end
        if not (el and el.kind == "image") then
            return
        end
    end
    local ow, oh = el.w, el.h
    local nw = math.max(8, math.floor(ow * ratio + 0.5))
    local nh = math.max(8, math.floor(oh * ratio + 0.5))
    if nw == ow and nh == oh then
        return
    end
    self:_normalizeImageWindow(el)
    local orig = self:_cloneElement(el)
    local old_region = self:_elementRegion(el)
    -- v64n:旋转图 + 原图在手 → base 缩放核心(绕窗口中心等比,单趟零累计模糊);
    -- 之后窗口字段/撤销由核心与下方共用逻辑完成(核心只动像素与 base 字段)
    if (el.rot or 0) ~= 0 and el._orig then
        local anchor_x, anchor_y = el.cx0 + el.cww / 2, el.cy0 + el.cwh / 2
        self:_applyImageBaseScaleF(el, ratio, ratio, anchor_x, anchor_y)
        el.w, el.h = nw, nh
        self:_cacheBBox(el)
        local region = self:_mergeRegions(old_region, self:_elementRegion(el))
        self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
        self:_clearRedo()
        self:_redrawRegion(region)
        UIManager:setDirty(self, "ui", region)
        self:_log("pinch scale image", string.format("%.2f", ratio))
        return
    end
    -- 重采样源:优先 base 原图(单趟,零累计模糊)
    -- 放大超基准分辨率先升级 pristine(v65c:从原文件重渲染)
    self:_upgradeImagePristine(el, el.cw * ratio, el.ch * ratio)
    local sfx, sfy = (el._sfx or 1) * ratio, (el._sfy or 1) * ratio
    local src = el._orig or el._bb
    local nbw, nbh
    if el._orig then
        local ow0, oh0 = el._orig:getWidth(), el._orig:getHeight()
        nbw = math.max(nw, math.floor(ow0 * sfx + 0.5))
        nbh = math.max(nh, math.floor(oh0 * sfy + 0.5))
    else
        local bbw, bbh = el._bb:getWidth(), el._bb:getHeight()
        nbw = math.max(nw, math.floor(bbw * ratio + 0.5))
        nbh = math.max(nh, math.floor(bbh * ratio + 0.5))
    end
    local scaled = RenderImage:scaleBlitBuffer(src, nbw, nbh, false)
    if not scaled then
        return
    end
    if scaled ~= el._bb then
        el._bb = scaled
    end
    if el._orig then
        el._sfx, el._sfy = sfx, sfy
    end
    -- base 窗口字段同因子缩放(窗口相对原图位置不变;保持浮点,取整只在渲染)
    el.cw = math.max(1, el.cw * ratio)
    el.ch = math.max(1, el.ch * ratio)
    el.cww = math.max(1, math.min(el.cww * ratio, el.cw))
    el.cwh = math.max(1, math.min(el.cwh * ratio, el.ch))
    el.cx0 = math.max(0, math.min(el.cx0 * ratio, el.cw - el.cww))
    el.cy0 = math.max(0, math.min(el.cy0 * ratio, el.ch - el.cwh))
    if el._orig then
        el._sfx, el._sfy = (el._sfx or 1) * ratio, (el._sfy or 1) * ratio
    end
    local cx, cy = el.x + ow / 2, el.y + oh / 2
    el.x = math.floor(cx - nw / 2)
    el.y = math.floor(cy - nh / 2)
    el.w, el.h = nw, nh
    self:_rebuildImageDisplay(el)
    self:_cacheBBox(el)
    local region = self:_mergeRegions(old_region, self:_elementRegion(el))
    self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
    self:_clearRedo()
    self:_redrawRegion(region)
    -- 尺寸突变用 ui 波形清残影(与角缩放提交同策略)
    UIManager:setDirty(self, "ui", region)
    self:_log("pinch scale image", string.format("%.2f", ratio))
end

function M:_flushImageFramePreview()
    if self._drag_preview_repaint_fn then
        UIManager:unschedule(self._drag_preview_repaint_fn)
        self._drag_preview_repaint_fn = nil
    end
    self._drag_preview_repaint_pending = false
    if not self.canvas_bb then
        return -- 关闭后挂起的回调:直接丢弃
    end
    local pos = self._drag_preview_pos
    local tr = self._transform
    if not (pos and tr and self._selected and self._selected.kind == "image") then
        return
    end
    local sb = tr.bbox
    local region
    if self._handle_mode == "rotate" then
        -- 旋转:原 bbox ∪ 旋转后四角外包
        local _, ext = self:_imageRotatePreview(tr, pos)
        region = self:_mergeRegions(
            self:_dirtyRegion(sb.x0, sb.y0, sb.x1, sb.y1, 16),
            self:_dirtyRegion(ext.x0, ext.y0, ext.x1, ext.y1, 16))
    else
        -- 目标窗口:裁剪=自由比例(_transformBBox),缩放=等比(_imageTransformBBox);
        -- 旋转图裁剪按 base 窗口四边形取外包(v64l,与提交同一数学)
        local nb
        if self._handle_mode == "crop" then
            if (self._selected.rot or 0) ~= 0 then
                local _, ext = self:_imageCropPreviewQuad(self._selected,
                    tr.handle, pos.x, pos.y)
                nb = ext
            else
                nb = self:_transformBBox(tr.handle, sb, pos.x, pos.y)
            end
        else
            if (self._selected.rot or 0) ~= 0 then
                -- 倾斜图缩放(v64m/v64o):边/角锚=同一指针数学的目标四边形外包
                local sel = self._selected
                local h = tr.handle
                local ext
                if h == "n" or h == "s" or h == "e" or h == "w" then
                    _, ext = self:_imageScalePreviewQuad(sel, h, pos.x, pos.y)
                else
                    _, ext = self:_imageScaleCornerQuad(sel, h, pos.x, pos.y)
                end
                nb = ext
            else
                nb = self:_imageTransformBBox(tr.handle, sb, pos.x, pos.y)
            end
        end
        -- 刷新区域 = 原窗口 ∪ 目标窗口(外扩盖住框线与四角手柄重画)
        region = self:_mergeRegions(
            self:_dirtyRegion(sb.x0, sb.y0, sb.x1, sb.y1, 16),
            self:_dirtyRegion(nb.x0, nb.y0, nb.x1, nb.y1, 16))
    end
    self._drag_preview_region = region
    if region then
        UIManager:setDirty(self, "partial", region)
    end
end

return M
