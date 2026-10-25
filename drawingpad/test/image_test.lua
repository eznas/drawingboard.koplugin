--[[--
drawingpad image_test — 图片对象(v64)自测:导入/渲染/选中锚点/模式切换/
移动/缩放/裁剪/撤销重做/橡皮删除/工程往返。
运行:cd 模拟器 koreader 目录 && ./luajit <插件>/drawingpad/test/image_test.lua
--]]

-- 自定位注入 package.path(不经 pluginloader 也能 require drawingpad.*)
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\]") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or (__t_dir .. "/..")
package.path = __t_plugin .. "/?.lua;" .. package.path

require("setupkoenv")
-- 前置初始化必须早于任何 ui/uimanager / device
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")

local DrawingCanvas = require("drawingpad.drawing_canvas")

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg, 2)
    end
end

local function newCanvas()
    return DrawingCanvas:new{ on_close = function() end }
end

local function section(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("PASS: " .. name)
    else
        print("FAIL: " .. name .. " → " .. tostring(err))
        os.exit(1)
    end
end

-- ============================ 工具 ============================

-- 造样图:左半黑右半白的 BB8 PNG
local function makeSamplePng(path, w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, 0, math.floor(w / 2), h, Blitbuffer.COLOR_BLACK)
    bb:writePNG(path)
    local f = io.open(path, "rb")
    local head = f and f:read(8)
    if f then f:close() end
    check(head == string.char(137, 80, 78, 71, 13, 10, 26, 10), "sample png magic")
end

-- 伪 PNG 头(只有 IHDR,用于尺寸预检单测;不会真正解码)
local function fakePngHeader(path, w, h)
    local function be32(v)
        return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
            math.floor(v / 256) % 256, v % 256)
    end
    local f = io.open(path, "wb")
    f:write(string.char(137, 80, 78, 71, 13, 10, 26, 10))
    f:write(string.char(0, 0, 0, 13))
    f:write("IHDR")
    f:write(be32(w))
    f:write(be32(h))
    f:write(string.char(8, 0, 0, 0))
    f:close()
end

local function grayAt(canvas, x, y)
    return canvas.canvas_bb:getPixel(math.floor(x), math.floor(y)).a
end

-- base 坐标 → 屏幕坐标(v64l 测试辅助):O = 显示中心 - R(rot)·窗口中心偏移
local function baseToScreen(el, bx, by)
    local rot = el.rot or 0
    local c, s = math.cos(rot), math.sin(rot)
    local wx, wy = bx - el.cw / 2, by - el.ch / 2
    local wcx = (el.cx0 + el.cww / 2) - el.cw / 2
    local wcy = (el.cy0 + el.cwh / 2) - el.ch / 2
    local dcx, dcy = el.x + el.w / 2, el.y + el.h / 2
    local ox = dcx - (c * wcx - s * wcy)
    local oy = dcy - (s * wcx + c * wcy)
    return ox + c * wx - s * wy, oy + s * wx + c * wy
end

-- images 目录像素文件计数(v65 零落盘断言)
local function imagesFileCount()
    local lfs = require("libs/libkoreader-lfs")
    local dir = DataStorage:getDataDir() .. "/drawingboard/images"
    local n = 0
    for f in lfs.dir(dir or "") do
        if f:match("^img_.*%.png$") then
            n = n + 1
        end
    end
    return n
end

-- bb 黑像素计数(重建一致性断言)
local function bbDarkCount(bb)
    local ffi = require("ffi")
    local s = ffi.cast("uint8_t*", bb.data)
    local n = 0
    for y = 0, bb:getHeight() - 1 do
        for x = 0, bb:getWidth() - 1 do
            if tonumber(s[bb.stride * y + x]) < 128 then
                n = n + 1
            end
        end
    end
    return n
end

-- ============================ 1. 尺寸预检 ============================

section("png header size + too large rejected", function()
    local c = newCanvas()
    local sample = "/tmp/dp_img_sample.png"
    makeSamplePng(sample, 120, 90)
    local w, h = c:_pngSize(sample)
    check(w == 120 and h == 90, "pngSize got " .. tostring(w) .. "x" .. tostring(h))

    local fake = "/tmp/dp_img_fake_big.png"
    fakePngHeader(fake, 3000, 2000)
    local fw, fh = c:_pngSize(fake)
    check(fw == 3000 and fh == 2000, "fake png size")

    -- 大图拒绝:stub showToast 依赖的 UIManager.show,防 headless 弹窗
    local orig_show = UIManager.show
    UIManager.show = function() end
    c:_importImageFile(fake)
    UIManager.show = orig_show
    check(#c.elements == 0, "too large image must be rejected")
end)

-- ============================ 2. 导入与渲染 ============================

section("import file → element + pixels + auto select", function()
    local c = newCanvas()
    local sample = "/tmp/dp_img_sample.png"
    c:_importImageFile(sample)
    check(#c.elements == 1, "one element after import")
    local el = c.elements[1]
    check(el.kind == "image", "kind=image")
    check(el.w == 120 and el.h == 90, "size kept 120x90, got " .. el.w .. "x" .. el.h)
    check(el.x == math.floor((c.canvas_w - 120) / 2), "centered x")
    check(el._bb and el._bb:getWidth() == 120 and el._bb:getHeight() == 90, "bb size == display size")
    check(el.src and el.src:match("%.png$"), "pixel copy src set")
    -- 像素:左半黑右半白
    check(grayAt(c, el.x + 30, el.y + 45) < 128, "left half dark")
    check(grayAt(c, el.x + 90, el.y + 45) > 200, "right half light")
    -- 自动切选择工具并选中
    check(c.tool == "select", "auto switch to select tool")
    check(c._selected == el, "auto selected")
    check(c._handle_mode == "scale", "handle mode = scale")
    -- 撤销记录
    c:_undo()
    check(#c.elements == 0, "undo removes image")
    c:_redo()
    check(#c.elements == 1 and c.elements[1].kind == "image", "redo restores image")
end)

-- ============================ 2b. 浏览器回调路径解析 ============================

section("picked callback: dir from save_folder + restore + uppercase PNG", function()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes("/tmp/dp_img_dir", "mode") ~= "directory" then
        pcall(lfs.mkdir, "/tmp/dp_img_dir")
    end
    makeSamplePng("/tmp/dp_img_dir/photo.png", 60, 40)
    makeSamplePng("/tmp/dp_img_dir/photo.PNG", 60, 40)
    -- 小写名(commitFile 已剥后缀):目录取自回调时的 save_folder,导入后恢复快照
    local c = newCanvas()
    c.save_folder = "/tmp/dp_img_dir" -- 模拟 commitFile 已写入文件所在目录
    c:_onImagePicked("photo", "")
    check(#c.elements == 1, "lowercase name imports from browsed dir")
    check(c.save_folder == "", "save_folder restored to snapshot")
    check(c.import_folder == "/tmp/dp_img_dir", "import_folder remembered")
    -- 大写 .PNG(commitFile 剥不掉,须直接使用不拼双扩展)
    local c2 = newCanvas()
    c2.save_folder = "/tmp/dp_img_dir"
    c2:_onImagePicked("photo.PNG", "")
    check(#c2.elements == 1, "uppercase .PNG imports without double extension")
    -- 文件不存在:不出元素不崩(stub show 防失败 toast 弹窗)
    local orig_show = UIManager.show
    UIManager.show = function() end
    local c3 = newCanvas()
    c3.save_folder = "/tmp/dp_img_dir"
    c3:_onImagePicked("missing", "")
    UIManager.show = orig_show
    check(#c3.elements == 0, "missing file adds nothing")
end)

-- ============================ 3. 选中/锚点/模式切换 ============================

section("anchors + mode toggle scale⇄crop", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el) -- 导入已选中;undo/redo 清空后重新选
    -- 四角锚点命中(bbox±4)
    check(c:_hitHandle(el.x - 4, el.y - 4) == "nw", "nw handle hit")
    check(c:_hitHandle(el.x + el.w + 4, el.y + el.h + 4) == "se", "se handle hit")
    check(c:_hitHandle(el.x - 60, el.y - 60) == nil, "far corner no hit")
    -- 图内点选三态循环:缩放→裁剪→旋转→缩放
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    check(c._handle_mode == "crop", "tap 1: crop")
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    check(c._handle_mode == "rotate", "tap 2: rotate")
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    check(c._handle_mode == "scale", "tap 3: back to scale")
    -- 点空白取消选中,模式复位
    c:onTap(nil, { pos = { x = 5, y = 5 } })
    check(c._selected == nil, "tap empty deselects")
    c:_setSelected(el)
    check(c._handle_mode == "scale", "mode resets on reselect")
end)

-- ============================ 4. 移动 ============================

section("move via body drag", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    local x0, y0 = el.x, el.y
    c:onPan(nil, { pos = { x = x0 + 60, y = y0 + 45 }, start_pos = { x = x0 + 60, y = y0 + 45 } })
    check(c._select_drag ~= nil, "body drag started")
    c:onPanRelease(nil, { pos = { x = x0 + 110, y = y0 + 75 } })
    check(el.x == x0 + 50 and el.y == y0 + 30, "moved by (50,30), got +" .. (el.x - x0) .. ",+" .. (el.y - y0))
    check(grayAt(c, el.x + 30, el.y + 45) < 128, "moved image dark half follows")
    c:_undo()
    check(el.x == x0 and el.y == y0, "undo restores position")
end)

-- ============================ 5. 缩放 ============================

section("scale via corner drag + undo/redo", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el)
    local x0, y0 = el.x, el.y
    -- se 角拖大 2x(bbox 角 = x0+w, y0+h;锚点视觉 +4)
    c:onPan(nil, { pos = { x = x0 + el.w + 4, y = y0 + el.h + 4 },
                   start_pos = { x = x0 + el.w + 4, y = y0 + el.h + 4 } })
    check(c._transform ~= nil and c._transform.handle == "se", "transform started at se")
    c:onPanRelease(nil, { pos = { x = x0 + 2 * el.w, y = y0 + 2 * el.h } })
    check(el.w == 240 and el.h == 180, "scaled to 240x180, got " .. el.w .. "x" .. el.h)
    check(el._bb:getWidth() == 240 and el._bb:getHeight() == 180, "bb resampled to display size")
    check(el.x == x0 and el.y == y0, "nw corner fixed")
    check(grayAt(c, el.x + 60, el.y + 90) < 128, "scaled dark half present")
    -- undo 恢复旧 bb 引用(120x90),redo 回 240x180
    c:_undo()
    check(el.w == 120 and el.h == 90 and el._bb:getWidth() == 120, "undo restores size+bb")
    c:_redo()
    check(el.w == 240 and el.h == 180, "redo re-applies scale")
end)

-- ============================ 6. 裁剪 ============================

section("crop via corner drag (content stays, window shrinks)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el)
    -- 切裁剪模式
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    check(c._handle_mode == "crop", "crop mode on")
    local x0, y0, w0, h0 = el.x, el.y, el.w, el.h
    -- se 角内收 40x40
    c:onPan(nil, { pos = { x = x0 + w0 + 4, y = y0 + h0 + 4 },
                   start_pos = { x = x0 + w0 + 4, y = y0 + h0 + 4 } })
    check(c._transform ~= nil, "crop transform started")
    c:onPanRelease(nil, { pos = { x = x0 + w0 - 40, y = y0 + h0 - 40 } })
    check(el.w == w0 - 40 and el.h == h0 - 40, "window shrunk to " .. el.w .. "x" .. el.h)
    check(el.x == x0 and el.y == y0, "content does not move (nw stays)")
    check(el._bb:getWidth() == w0 and el._bb:getHeight() == h0, "bb keeps full pixels (non-destructive)")
    -- 被裁掉的右侧区域恢复白
    check(grayAt(c, el.x + el.w + 10, el.y + el.h / 2) > 200, "cropped-away area restored to white")
    -- 剩余内容仍左黑右白(60 黑 + 20 白)
    check(grayAt(c, el.x + 10, el.y + el.h / 2) < 128, "kept left dark")
    check(grayAt(c, el.x + el.w - 5, el.y + el.h / 2) > 200, "kept right light")
    c:_undo()
    check(el.w == w0 and el.h == h0, "undo restores crop")
end)

-- ============================ 6b. 等比角缩放 / 边锚单轴(v64c) ============================

section("corner scale keeps aspect ratio, edge handle single-axis", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el)
    local x0, y0 = el.x, el.y
    -- 角锚等比:se 拖到 fx=1.667/fy=1.333 的位置 → f=均值 1.5,比例保持 4:3
    c:onPan(nil, { pos = { x = x0 + el.w + 4, y = y0 + el.h + 4 },
                   start_pos = { x = x0 + el.w + 4, y = y0 + el.h + 4 } })
    check(c._transform ~= nil and c._transform.handle == "se", "se transform")
    c:onPanRelease(nil, { pos = { x = x0 + 200, y = y0 + 120 } })
    check(el.w == 180 and el.h == 135, "uniform corner scale 180x135, got " .. el.w .. "x" .. el.h)
    check(math.abs(el.w / el.h - 120 / 90) < 0.01, "aspect preserved")
    c:_undo()
    check(el.w == 120 and el.h == 90, "undo")
    c:_setSelected(el) -- undo 清空选中,重新选(模式复位 scale)
    -- 边锚:n 边中点命中,纵向拉伸不改宽
    check(c:_hitHandle(x0 + 60, y0) == "n", "n edge handle hit")
    check(c:_hitHandle(x0 + el.w, y0 + 45) == "e", "e edge handle hit")
    c:onPan(nil, { pos = { x = x0 + 60, y = y0 }, start_pos = { x = x0 + 60, y = y0 } })
    check(c._transform ~= nil and c._transform.handle == "n", "n transform")
    c:onPanRelease(nil, { pos = { x = x0 + 60, y = y0 - 45 } })
    check(el.w == 120 and el.h == 135, "edge drag changes height only: " .. el.w .. "x" .. el.h)
    check(el.y == y0 - 45, "n edge moves top up")
end)

-- ============================ 6c. 双指捏合/张开缩放(v64c) ============================

section("pinch/spread scales image about center", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    local cx, cy = el.x + 60, el.y + 45
    -- 捏合(双指间距 100→50):0.5x,中心不动
    c:onPinch(nil, { pos = { x = cx, y = cy }, start_span = 100, span = 50 })
    check(el.w == 60 and el.h == 45, "pinch 0.5x: " .. el.w .. "x" .. el.h)
    check(math.abs((el.x + 30) - cx) <= 1 and math.abs((el.y + 22) - cy) <= 1,
        "pinch keeps center")
    c:_undo()
    check(el.w == 120 and el.h == 90, "undo pinch")
    -- 张开(100→150):1.5x
    c:onSpread(nil, { pos = { x = cx, y = cy }, start_span = 100, span = 150 })
    check(el.w == 180 and el.h == 135, "spread 1.5x: " .. el.w .. "x" .. el.h)
    -- 间距几乎没变:不动作
    local w_before = el.w
    c:onPinch(nil, { pos = { x = cx, y = cy }, start_span = 100, span = 102 })
    check(el.w == w_before, "negligible span change ignored")
    c:_undo()
    check(el.w == 120 and el.h == 90, "undo spread")
    -- 未选中时手势落在图片上:自动选中并缩放
    c:_setSelected(nil)
    c:_setTool("brush")
    c:onPinch(nil, { pos = { x = el.x + 60, y = el.y + 45 }, start_span = 100, span = 200 })
    check(c._selected == el and c.tool == "select", "pinch on image auto-selects")
    check(el.w == 240 and el.h == 180, "pinch on unselected image scales: " .. el.w .. "x" .. el.h)
end)

-- ============================ 6d. 裁剪边锚(横向/纵向裁剪)============================

section("crop edge anchors: top/bottom/left/right single-axis crop", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el)
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } }) -- 切裁剪
    check(c._handle_mode == "crop", "crop mode")
    -- 裁剪模式四边锚命中
    check(c:_hitHandle(el.x + 60, el.y) == "n", "crop n edge hit")
    check(c:_hitHandle(el.x + el.w, el.y + 45) == "e", "crop e edge hit")
    -- 拖 n 边下移 30:从顶部裁掉 30(内容不动,宽不变)
    c:onPan(nil, { pos = { x = el.x + 60, y = el.y }, start_pos = { x = el.x + 60, y = el.y } })
    check(c._transform ~= nil and c._transform.handle == "n", "crop n transform")
    local x0, y0, w0, h0 = el.x, el.y, el.w, el.h
    c:onPanRelease(nil, { pos = { x = x0 + 60, y = y0 + 30 } })
    check(el.y == y0 + 30 and el.h == h0 - 30, "top crop y+30 h-30")
    check(el.x == x0 and el.w == w0, "width unchanged")
    check(el._bb:getHeight() == 90, "bb keeps full pixels")
    check(grayAt(c, el.x + 10, el.y + 5) < 128, "kept content below crop line")
    c:_undo()
    check(el.y == y0 and el.h == h0, "undo crop")
    c:_setSelected(el) -- undo 清空选中,重新选(模式复位 scale)
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } }) -- 再切裁剪
    check(c._handle_mode == "crop", "crop mode again")
    -- e 边左移:横向裁右侧
    c:onPan(nil, { pos = { x = el.x + el.w, y = el.y + 45 },
                   start_pos = { x = el.x + el.w, y = el.y + 45 } })
    check(c._transform ~= nil and c._transform.handle == "e", "crop e transform")
    c:onPanRelease(nil, { pos = { x = x0 + w0 - 25, y = y0 + 45 } })
    check(el.w == w0 - 25 and el.h == h0, "right crop w-25")
end)

-- ============================ 6e. 作画活动保持(standby/suspend 计时) ============================

section("standby hold on activity", function()
    local base = UIManager._prevent_standby_count
    local c = newCanvas()
    c:_noteActivity()
    check(UIManager._prevent_standby_count == base + 1, "preventStandby acquired")
    check(c._standby_held == true, "held flag")
    c:_noteActivity() -- 未过期:重复活动不叠加引用
    check(UIManager._prevent_standby_count == base + 1, "no double-acquire")
    c._activity_until = os.time() - 1 -- 过期:下一次活动先释放再重取(net 0)
    c:_noteActivity()
    check(UIManager._prevent_standby_count == base + 1, "release+reacquire balanced")
    c:onCloseWidget()
    check(UIManager._prevent_standby_count == base, "released on close")
    check(c._standby_held == false, "held cleared on close")
end)

-- ============================ 6f. 裁剪非破坏性:反向拖动恢复隐藏内容 ============================

section("reverse crop drag restores hidden content", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el)
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    check(c._handle_mode == "crop", "crop mode")
    local x0, y0, w0, h0 = el.x, el.y, el.w, el.h
    -- se 内收 40x40:裁掉右侧与底部
    c:onPan(nil, { pos = { x = x0 + w0 + 4, y = y0 + h0 + 4 },
                   start_pos = { x = x0 + w0 + 4, y = y0 + h0 + 4 } })
    c:onPanRelease(nil, { pos = { x = x0 + w0 - 40, y = y0 + h0 - 40 } })
    check(el.w == w0 - 40 and el.h == h0 - 40, "cropped to " .. el.w .. "x" .. el.h)
    check(el._bb:getWidth() == w0 and el._bb:getHeight() == h0, "full pixels kept")
    -- 反向拖 se 角向外:恢复被隐藏的原图内容
    c:onPan(nil, { pos = { x = x0 + w0 - 36, y = y0 + h0 - 36 },
                   start_pos = { x = x0 + w0 - 36, y = y0 + h0 - 36 } })
    check(c._transform ~= nil, "reverse transform on")
    c:onPanRelease(nil, { pos = { x = x0 + w0 + 4, y = y0 + h0 + 4 } })
    check(el.w == w0 and el.h == h0, "reverse drag restores size, got " .. el.w .. "x" .. el.h)
    check(el.cx0 == 0 and el.cy0 == 0, "window back to origin")
    check(grayAt(c, el.x + w0 - 10, el.y + h0 / 2) > 200, "right light content restored")
    check(grayAt(c, el.x + 10, el.y + h0 - 5) < 128, "bottom dark content restored")
    -- 拖出图像边界:窗口钳到 _bb 边界,不超出
    c:onPan(nil, { pos = { x = x0 + w0 + 4, y = y0 + h0 + 4 },
                   start_pos = { x = x0 + w0 + 4, y = y0 + h0 + 4 } })
    c:onPanRelease(nil, { pos = { x = x0 + w0 + 200, y = y0 + h0 + 200 } })
    check(el.w == w0 and el.h == h0, "clamped to image bounds")
    check(el.x == x0 and el.y == y0, "position stable when clamped")
    -- 撤销链:三次裁剪操作逐一可撤销
    c:_undo()
    check(el.w == w0 and el.h == h0, "undo no-op clamp")
end)

-- ============================ 6g. 旋转模式(v64f) ============================

section("rotate mode: 90deg resample + window reset + undo", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el)
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } }) -- crop
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } }) -- rotate
    check(c._handle_mode == "rotate", "rotate mode")
    -- 旋转模式无边锚,四角空心圆锚照常命中
    check(c:_hitHandle(el.x + el.w, el.y + 45) == nil, "no edge anchors in rotate")
    check(c:_hitHandle(el.x + el.w + 4, el.y + el.h + 4) == "se", "corner anchors hit")
    -- 拖 se 角转 90°(handle 偏移 (64,49) 旋转 90° → (-49,64))
    local cx, cy = el.x + el.w / 2, el.y + el.h / 2
    c:onPan(nil, { pos = { x = el.x + el.w + 4, y = el.y + el.h + 4 },
                   start_pos = { x = el.x + el.w + 4, y = el.y + el.h + 4 } })
    check(c._transform ~= nil, "rotate transform on")
    c:onPanRelease(nil, { pos = { x = cx - 49, y = cy + 64 } })
    check(el.w == 90 and el.h == 120, "rotated bounding 90x120, got " .. el.w .. "x" .. el.h)
    check(el.cx0 == 0 and el.cy0 == 0, "window reset to full")
    -- 黑半(原左 60px)旋转后占满一整半
    local top = grayAt(c, el.x + el.w / 2, el.y + 15)
    local bottom = grayAt(c, el.x + el.w / 2, el.y + el.h - 15)
    check((top < 128 and bottom > 200) or (top > 200 and bottom < 128),
        "black half became one full half, top=" .. top .. " bottom=" .. bottom)
    c:_undo()
    check(el.w == 120 and el.h == 90, "undo rotate restores")
end)

-- ============================ 6h. 裁剪后旋转(v64g 守卫修复) ============================

section("rotate after crop: window rides in base space (v64l)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 样图左半黑:裁剪到左半(base 窗口 [0,60)x[0,90)),内容屏幕位置不动
    c:_applyImageCrop(el, "se", el.x + 60, el.y + 90)
    check(el.cww == 60 and el.cwh == 90, "base window 60x90, got " .. el.cww .. "x" .. el.cwh)
    check(el.w == 60 and el.h == 90, "display dims 60x90")
    local bx, by, bw2, bh2 = el.cx0, el.cy0, el.cww, el.cwh
    c:_applyImageRotate(el, math.pi / 2)
    check(el.cx0 == bx and el.cy0 == by and el.cww == bw2 and el.cwh == bh2,
        "window metadata unchanged by rotation")
    check(el.w == 90 and el.h == 60, "rotated display 90x60, got " .. el.w .. "x" .. el.h)
    check(el.cw == 120 and el.ch == 90, "base dims kept")
    c:_renderAll() -- 直调不走手势无重绘,像素断言前手动刷新
    -- 窗口=黑半,旋转 90° 后整窗全黑(_disp 渲染路径)
    check(grayAt(c, el.x + el.w / 2, el.y + 15) < 128, "black rendered via _disp")
    check(grayAt(c, el.x + 8, el.y + el.h / 2) < 128, "content left")
    check(grayAt(c, el.x + el.w - 8, el.y + el.h / 2) < 128, "content right")
end)

-- 6h2. 倾斜窗口:白角恒在窗口外 + 窗口多轮旋转贴原图不动(v64l)
section("tilted window: white corners outside, window glued across rotations", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_applyImageCrop(el, "se", el.x + 60, el.y + 90) -- 左半黑窗口
    c:_applyImageRotate(el, math.rad(30))
    c:_renderAll()
    check((el.rot or 0) ~= 0, "tilted")
    check(el._disp ~= nil, "display cache built")
    -- 显示 AABB 四角=白(30° 倾斜下窗口是内接四边形,角在窗口外)
    check(grayAt(c, el.x + 2, el.y + 2) > 250, "AABB corner white TL, got "
        .. grayAt(c, el.x + 2, el.y + 2))
    check(grayAt(c, el.x + el.w - 3, el.y + el.h - 3) > 250, "AABB corner white BR")
    -- 窗口内容黑:显示中心
    check(grayAt(c, el.x + el.w / 2, el.y + el.h / 2) < 128, "window content black")
    -- 再转 30°:窗口 base 字段纹丝不动(随图走)
    local bx, by, bw2, bh2 = el.cx0, el.cy0, el.cww, el.cwh
    c:_applyImageRotate(el, math.rad(30))
    check(el.cx0 == bx and el.cy0 == by and el.cww == bw2 and el.cwh == bh2,
        "window glued to original image")
end)

-- ============================ 6i. 旋转白角不累积 + 框贴倾斜内容(v64h) ============================

section("rotation does not accumulate white padding, frame hugs content", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setSelected(el)
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    check(c._handle_mode == "rotate", "rotate mode")
    local orig = c:_cloneElement(el) -- 旋转前快照(供末尾 undo)
    -- 30° 两次:基准重采样,bb = 内容 60° 包围(~138x149),而非逐轮放大(198x194)
    c:_applyImageRotate(el, math.rad(30))
    c:_applyImageRotate(el, math.rad(30))
    local expect_w = math.floor(120 * math.abs(math.cos(math.rad(60)))
        + 90 * math.abs(math.sin(math.rad(60))) + 0.5)
    local expect_h = math.floor(120 * math.abs(math.sin(math.rad(60)))
        + 90 * math.abs(math.cos(math.rad(60))) + 0.5)
    check(math.abs(el.w - expect_w) <= 1 and math.abs(el.h - expect_h) <= 1,
        "no accumulation: " .. el.w .. "x" .. el.h .. " expect " .. expect_w .. "x" .. expect_h)
    check(math.abs(el.rot - math.rad(60)) < 0.01, "total angle tracked")
    check(el.cw == 120 and el.ch == 90, "base dims kept")
    -- 框贴倾斜内容:四角 = 中心 ± R(60°)·(60,45)——不得落在 AABB 四角上
    local corners = c:_frameCorners(el)
    local cx, cy = el.x + el.w / 2, el.y + el.h / 2
    local aabb = {
        { cx + el.w / 2, cy + el.h / 2 }, { cx - el.w / 2, cy + el.h / 2 },
        { cx + el.w / 2, cy - el.h / 2 }, { cx - el.w / 2, cy - el.h / 2 },
    }
    local mind = math.huge
    for _, a in ipairs(aabb) do
        for _, p in ipairs(corners) do
            local d = math.sqrt((a[1] - p.x) ^ 2 + (a[2] - p.y) ^ 2)
            mind = math.min(mind, d)
        end
    end
    check(mind > 20, "frame corners not at AABB corners (mind=" .. mind .. ")")
    -- v64k:多次旋转内容像素不丢——累积分支曾半幅错位,每转一轮内容外推一轮
    -- 直至全白(尺寸断言测不出,必须数 bb 黑像素;样图半黑≈5400)
    local ffi = require("ffi")
    local s = ffi.cast("uint8_t*", el._bb.data)
    local st, dark = el._bb.stride, 0
    for yy = 0, el._bb:getHeight() - 1 do
        for xx = 0, el._bb:getWidth() - 1 do
            if s[st * yy + xx] < 128 then
                dark = dark + 1
            end
        end
    end
    check(dark > 3000, "multi-rotate keeps content pixels, dark=" .. dark)
    -- undo(直调不经手势,手动压记录;orig 快照持有旧 _bb 引用+rot/cw/ch)
    c:_pushUndo({ kind = "transform", el = el, orig = orig, final = c:_cloneElement(el) })
    c:_undo()
    check(el.w == 120 and el.h == 90 and (el.rot or 0) == 0, "undo restores")
end)

-- ============================ 6j. 旋转图变换烧平 + OBB 边锚(v64j) ============================

section("crop on tilted image: base-space window, no bake (v64l)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_applyImageRotate(el, math.pi / 2) -- 120x90 → 显示 90x120
    check((el.rot or 0) ~= 0, "rotated")
    -- 倾斜图裁剪:拖 se 角到 base(60,90) 的屏幕位置 → base 窗口 [0,60)x[0,90)
    local sx, sy = baseToScreen(el, 60, 90)
    c:_applyImageCrop(el, "se", sx, sy)
    check(el.cww == 60 and el.cwh == 90, "base window 60x90, got "
        .. el.cww .. "x" .. el.cwh)
    check((el.rot or 0) ~= 0 and el.cw == 120 and el.ch == 90,
        "rotation NOT baked, base dims kept")
    check(el.w == 90 and el.h == 60, "display=窗口 90° 包围 90x60, got "
        .. el.w .. "x" .. el.h)
    -- 框角=窗口角:四角到显示中心距离 ≈ sqrt(45²+30²)(pad≈4 外扩)
    local corners = c:_frameCorners(el)
    local ccx, ccy = el.x + el.w / 2, el.y + el.h / 2
    local expect_r = math.sqrt(45 ^ 2 + 30 ^ 2)
    for i, p in ipairs(corners) do
        local r = math.sqrt((p.x - ccx) ^ 2 + (p.y - ccy) ^ 2)
        check(math.abs(r - expect_r - 4) < 3,
            "frame corner " .. i .. " at window corner, r=" .. string.format("%.1f", r))
    end
    -- bb 仍是整图(隐藏内容可反向恢复)
    check(el._bb:getWidth() == 90 and el._bb:getHeight() == 120, "full bb kept")
    local sx2, sy2 = baseToScreen(el, 120, 90)
    c:_applyImageCrop(el, "se", sx2, sy2)
    check(el.cww == 120 and el.cwh == 90, "reverse crop on tilted restores full")
end)

section("aniso scale on rotated image: base core with orig, bake only without (v64n)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_applyImageRotate(el, math.rad(30))
    check((el.rot or 0) ~= 0 and el._orig ~= nil, "tilted with pristine orig")
    -- v64n:有 _orig 时无 handle 单轴拉伸走 base 核心(均值因子等比),不烧平
    local cw_before = el.cw
    local w_before = el.w
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y, x1 = el.x + el.w + 40, y1 = el.y + el.h })
    check((el.rot or 0) ~= 0, "rotation kept (base core, no bake)")
    local f_avg = ((w_before + 40) / w_before + 1) / 2
    check(math.abs(el.cw - cw_before * f_avg) < 2, "base scaled by avg factor, got "
        .. el.cw .. " expect ~" .. cw_before * f_avg)
    -- 无 _orig(模拟工程重载):单轴拉伸仍烧平(v64j 兜底语义保留)
    el._orig = nil
    c:_applyImageRotate(el, math.rad(5))
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y, x1 = el.x + el.w + 40, y1 = el.y + el.h })
    check((el.rot or 0) == 0, "rotation baked without orig")
    check(el.cww == el.w and el.cwh == el.h and el.cx0 == 0,
        "window reset to full after bake")
end)

section("edge anchors hug tilted content (OBB midpoints)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 宽图 200x90(长边中点距角点曼哈顿距离 >48,不被角命中抢先;90 短边中点
    -- 距角 ≤45 恒被角吃,既有优先级,非本次范围);v64l 裁剪图须同时设 base 字段
    local img = Blitbuffer.new(200, 90, Blitbuffer.TYPE_BB8)
    img:paintRect(0, 0, 200, 90, Blitbuffer.COLOR_WHITE)
    el._bb = img
    el.cx0, el.cy0 = 0, 0
    el.cw, el.ch = 200, 90
    el.cww, el.cwh = 200, 90
    el.w, el.h = 200, 90
    c:_cacheBBox(el)
    c:_setSelected(el)
    c:_applyImageRotate(el, math.rad(30))
    c:_cacheBBox(el)
    c:_setSelected(el)
    check(c._handle_mode == "scale", "scale mode")
    -- OBB 边中点 = 倾斜框相邻角点均值,命中对应边
    local pts = c:_frameCorners(el)
    local mn = { (pts[1].x + pts[2].x) / 2, (pts[1].y + pts[2].y) / 2 }
    check(c:_hitHandle(mn[1], mn[2]) == "n", "OBB top edge midpoint hits n")
    local ms = { (pts[3].x + pts[4].x) / 2, (pts[3].y + pts[4].y) / 2 }
    check(c:_hitHandle(ms[1], ms[2]) == "s", "OBB bottom edge midpoint hits s")
    -- AABB 上边中点(30° 倾斜下在 OBB 外 ~32px)不再误报 n
    local b = el._bbox
    local hit = c:_hitHandle((b.x0 + b.x1) / 2, b.y0)
    check(hit == nil, "AABB top midpoint no longer mis-hits, got " .. tostring(hit))
    -- 裁剪模式同款 OBB 边锚命中(点一下本体:scale→crop)
    c:onTap(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 } })
    check(c._handle_mode == "crop", "crop mode")
    check(c:_hitHandle(mn[1], mn[2]) == "n", "crop mode OBB top midpoint hits n")
end)

-- ============================ 6k. 多轮裁剪⇄旋转:窗口钉在原图,框不扩大(v64l 用户复现) ============================

section("multi crop+rotate cycles: window glued to image, frame never grows", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 轮 1:裁剪到左半(黑半)再转 30°
    c:_applyImageCrop(el, "se", el.x + 60, el.y + 90)
    local bx, by, bw2, bh2 = el.cx0, el.cy0, el.cww, el.cwh
    c:_applyImageRotate(el, math.rad(30))
    check(bx == el.cx0 and by == el.cy0 and bw2 == el.cww and bh2 == el.cwh,
        "R1 window glued")
    -- 轮 2:倾斜态再裁剪(base 窗口收窄到 50)再转 30°
    local sx, sy = baseToScreen(el, 50, 90)
    c:_applyImageCrop(el, "se", sx, sy)
    check(el.cww == 50, "R2 window 50 wide, got " .. el.cww)
    bx, by, bw2, bh2 = el.cx0, el.cy0, el.cww, el.cwh
    c:_applyImageRotate(el, math.rad(30))
    check(bx == el.cx0 and by == el.cy0 and bw2 == el.cww and bh2 == el.cwh,
        "R2 window glued")
    -- 轮 3:再转 30°(累计 90°)
    c:_applyImageRotate(el, math.rad(30))
    check(bx == el.cx0 and by == el.cy0 and bw2 == el.cww and bh2 == el.cwh,
        "R3 window glued")
    check(math.abs((el.rot or 0) - math.rad(90)) < 0.01, "total 90deg")
    -- 显示=窗口 90° 包围(50x90 → 90x50)——旧模型此处白角复利框逐轮膨胀
    check(el.w == 90 and el.h == 50, "final display 90x50, got " .. el.w .. "x" .. el.h)
    -- 框角=窗口角:四角到中心距离 ≈ sqrt(45²+25²)+pad4
    local corners = c:_frameCorners(el)
    local ccx, ccy = el.x + el.w / 2, el.y + el.h / 2
    local expect_r = math.sqrt(45 ^ 2 + 25 ^ 2)
    for i, p in ipairs(corners) do
        local r = math.sqrt((p.x - ccx) ^ 2 + (p.y - ccy) ^ 2)
        check(math.abs(r - expect_r - 4) < 3,
            "frame corner " .. i .. " hugs window, r=" .. string.format("%.1f", r))
    end
    -- 渲染:窗口全黑(裁掉的是白半),内容可见
    c:_renderAll()
    check(grayAt(c, el.x + el.w / 2, el.y + el.h / 2) < 128,
        "content visible after 3 cycles")
    -- 反向裁剪恢复全图(整图恒在 _bb;旋转语义不丢)
    local sx2, sy2 = baseToScreen(el, 120, 90)
    c:_applyImageCrop(el, "se", sx2, sy2)
    check(el.cww == 120 and el.cwh == 90, "reverse crop restores full window")
    check((el.rot or 0) ~= 0, "rotation kept while restoring")
    check(el.w == 90 and el.h == 120, "full window display 90x120")
    c:_renderAll()
    -- 全图窗口:90° 下黑半在上
    check(grayAt(c, el.x + el.w / 2, el.y + 15) < 128, "restored black half visible")
    check(grayAt(c, el.x + el.w / 2, el.y + el.h - 15) > 200, "restored white half visible")
end)

-- ============================ 6m. 倾斜图边锚拉伸沿图片自身轴(v64m) ============================

section("tilted edge stretch: scales along image axes, frame angle kept", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_applyImageRotate(el, math.rad(30))
    check((el.rot or 0) ~= 0, "tilted")
    -- 拖 e 边锚到 base x=240 → fx=2(全图窗口 120→240);对侧(左)边屏幕位置不动
    local left_before = { baseToScreen(el, 0, el.ch / 2) }
    local sx, sy = baseToScreen(el, 240, el.ch / 2)
    -- nb 仅占位(base 路径不用;但须与当前尺寸不同以越过早退)
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y,
        x1 = el.x + el.w + 100, y1 = el.y + el.h }, "e", sx, sy)
    check((el.rot or 0) ~= 0, "rotation kept (no bake)")
    check(math.abs(el.cw - 240) < 2, "base width doubled, got " .. el.cw)
    check(math.abs(el.cww - el.cw) < 2, "window rides with scale")
    -- 显示=240x90@30° 包围:253x198
    local ew = math.floor(240 * math.cos(math.rad(30)) + 90 * math.sin(math.rad(30)) + 0.5)
    local eh = math.floor(240 * math.sin(math.rad(30)) + 90 * math.cos(math.rad(30)) + 0.5)
    check(math.abs(el.w - ew) <= 1 and math.abs(el.h - eh) <= 1,
        "display bounding " .. el.w .. "x" .. el.h .. " expect " .. ew .. "x" .. eh)
    -- 左边(锚边)屏幕不动
    local left_after = { baseToScreen(el, 0, el.ch / 2) }
    check(math.abs(left_after[1] - left_before[1]) <= 1
        and math.abs(left_after[2] - left_before[2]) <= 1, "anchor edge fixed on screen")
    -- 内容存活:bb 黑像素(拉伸后黑半 ≈ 240*90/2)
    local ffi = require("ffi")
    local s = ffi.cast("uint8_t*", el._bb.data)
    local st, dark = el._bb.stride, 0
    for yy = 0, el._bb:getHeight() - 1 do
        for xx = 0, el._bb:getWidth() - 1 do
            if s[st * yy + xx] < 128 then
                dark = dark + 1
            end
        end
    end
    check(dark > 8000, "content pixels survived, dark=" .. dark)
    c:_renderAll()
    check(grayAt(c, el.x + el.w * 0.3, el.y + el.h * 0.4) < 200,
        "stretched content rendered")
end)

section("edge anchor grab beats corner on tilted image (nearest-anchor hit)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_applyImageRotate(el, math.rad(30))
    c:_cacheBBox(el)
    c:_setSelected(el)
    check(c._handle_mode == "scale", "scale mode")
    -- e 边中点(30° 倾斜下距角点两轴曼哈顿 ≤48,旧"角优先"规则被角吃掉)
    local pts = c:_frameCorners(el)
    local mx, my = (pts[2].x + pts[3].x) / 2, (pts[2].y + pts[3].y) / 2
    check(c:_hitHandle(mx, my) == "e", "e edge midpoint hits e, got "
        .. tostring(c:_hitHandle(mx, my)))
    -- 角点本身仍命中角
    check(c:_hitHandle(pts[3].x, pts[3].y) == "se", "se corner still hits se")
end)

section("tilted corner scale preview quad follows image angle (v64m/v64o)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_applyImageRotate(el, math.rad(30))
    -- 角锚预览(v64o 指针数学):指针沿对角线投影到 2 倍处 → f=2 绕对角(0,0)
    local ax, ay = 0, 0
    local dxg, dyg = el.cww, el.cwh
    local sx, sy = baseToScreen(el, ax + dxg * 2, ay + dyg * 2)
    local pts, ext = c:_imageScaleCornerQuad(el, "se", sx, sy)
    local ccx, ccy = (ext.x0 + ext.x1) / 2, (ext.y0 + ext.y1) / 2
    local expect_r = math.sqrt(120 ^ 2 + 90 ^ 2)
    for i, p in ipairs(pts) do
        local r = math.sqrt((p.x - ccx) ^ 2 + (p.y - ccy) ^ 2)
        check(math.abs(r - expect_r) < 2,
            "quad corner " .. i .. " at tilted window corner, r="
            .. string.format("%.1f", r) .. " expect " .. string.format("%.1f", expect_r))
    end
    -- 四边形不与等比 AABB 四角重合(30° 倾斜下错开 >20px)
    local aabb_corner = { x = ext.x1, y = ext.y1 }
    local mind = math.huge
    for _, p in ipairs(pts) do
        local d = math.sqrt((p.x - aabb_corner.x) ^ 2 + (p.y - aabb_corner.y) ^ 2)
        mind = math.min(mind, d)
    end
    check(mind > 20, "quad not axis-aligned AABB (mind=" .. string.format("%.1f", mind) .. ")")
end)

section("repeated scaling stays sharp (pristine single-pass resample, v64n)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 黑白硬边样图:缩上去再缩回来,bb 尺寸还原时黑像素计数应与原始一致
    -- (旧实现逐次对当前 bb 插值,黑白边界逐轮发糊,硬边像素数漂移)
    local ffi = require("ffi")
    local function darkCount(bb)
        local s = ffi.cast("uint8_t*", bb.data)
        local n = 0
        for yy = 0, bb:getHeight() - 1 do
            for xx = 0, bb:getWidth() - 1 do
                if s[bb.stride * yy + xx] < 128 then
                    n = n + 1
                end
            end
        end
        return n
    end
    local orig_dark = darkCount(el._bb)
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y,
        x1 = el.x + el.w * 2, y1 = el.y + el.h * 2 })
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y,
        x1 = el.x + el.w / 2, y1 = el.y + el.h / 2 })
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y,
        x1 = el.x + el.w * 2, y1 = el.y + el.h * 2 })
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y,
        x1 = el.x + el.w / 2, y1 = el.y + el.h / 2 })
    check(el._bb:getWidth() == 120 and el._bb:getHeight() == 90,
        "bb dims restored, got " .. el._bb:getWidth() .. "x" .. el._bb:getHeight())
    local drift = math.abs(darkCount(el._bb) - orig_dark)
    check(drift <= orig_dark * 0.02, "hard-edge pixel count stable after 4 scales, drift="
        .. drift .. " (orig=" .. orig_dark .. ")")
end)

section("corner drag fixes opposite anchor (v64o)", function()
    for _, rot in ipairs({ 0, math.rad(30) }) do
        local c = newCanvas()
        c:_importImageFile("/tmp/dp_img_sample.png")
        local el = c.elements[1]
        if rot ~= 0 then
            c:_applyImageRotate(el, rot)
        end
        c:_setSelected(el)
        local pts = c:_frameCorners(el)
        local ne_before = { pts[2].x, pts[2].y }
        -- 手势拖 SW 角锚放大
        c:onPan(nil, { pos = { x = pts[4].x, y = pts[4].y },
                       start_pos = { x = pts[4].x, y = pts[4].y } })
        c:onPanRelease(nil, { pos = { x = pts[4].x - 60, y = pts[4].y + 60 } })
        local pts2 = c:_frameCorners(el)
        local dx = math.abs(pts2[2].x - ne_before[1])
        local dy = math.abs(pts2[2].y - ne_before[2])
        check(dx <= 2 and dy <= 2, string.format("rot%.0f: NE anchor fixed, drift=(%.1f,%.1f)",
            math.deg(rot), dx, dy))
        -- 窗口不越界:cx0/cy0 ∈ [0, cw−cww]
        check(el.cx0 >= 0 and el.cx0 <= el.cw - el.cww and
              el.cy0 >= 0 and el.cy0 <= el.ch - el.cwh,
            string.format("rot%.0f: window in bounds, cx0=%d cy0=%d", math.deg(rot), el.cx0, el.cy0))
        -- 渲染可见
        c:_renderAll()
        check(grayAt(c, el.x + el.w / 2, el.y + el.h / 2) < 250, "content rendered")
    end
end)

section("crop then tilted corner scale then rotate keeps alignment (v64q)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 裁剪左半 → 转 30° → 角锚缩放 ×1.3 → 再转 30°
    local sx, sy = baseToScreen(el, 60, 90)
    c:_applyImageCrop(el, "se", sx, sy)
    c:_applyImageRotate(el, math.rad(30))
    local tx, ty = baseToScreen(el, el.cww * 1.3, el.cwh * 1.3)
    c:_applyImageScale(el, { x0 = el.x, y0 = el.y,
        x1 = el.x + el.w * 1.3, y1 = el.y + el.h * 1.3 }, "se", tx, ty)
    local sfx_v64q, sfy_v64q = el._sfx, el._sfy
    -- v65c:×1.3 可能触发 pristine 升级(因子重定基≈1),断言不变式
    -- base=pristine×因子(旧版漏更 sfx 时该式必破)
    check(math.abs(el.cw - el._orig:getWidth() * el._sfx) < 0.5
        and math.abs(el.ch - el._orig:getHeight() * el._sfy) < 0.5,
        "cumulative factor tracks base/pristine after base scale, sfx="
        .. tostring(el._sfx))
    -- 内容对齐:窗口内 base 点的 bb 像素 = pristine(b/sf)(旧版漏更 sfx,旋转即错位)
    local ffi = require("ffi")
    c:_applyImageRotate(el, math.rad(30))
    check(el._sfx == sfx_v64q and el._sfy == sfy_v64q, "factor unchanged by rotation")
    local rot = el.rot
    local cc, ss = math.cos(rot), math.sin(rot)
    local bbw, bbh = el._bb:getWidth(), el._bb:getHeight()
    local sb = ffi.cast("uint8_t*", el._bb.data)
    local so = ffi.cast("uint8_t*", el._orig.data)
    local bad, n = 0, 0
    for by = 10, math.floor(el.ch) - 10, 15 do
        for bx = 10, math.floor(el.cw) - 10, 15 do
            local rx, ry = bx - el.cw / 2, by - el.ch / 2
            local px = bbw / 2 + cc * rx - ss * ry
            local py = bbh / 2 + ss * rx + cc * ry
            local expect = so[el._orig.stride * math.floor(by / el._sfy) + math.floor(bx / el._sfx)]
            local got = sb[el._bb.stride * math.floor(py) + math.floor(px)]
            n = n + 1
            if math.abs(expect - got) > 40 then
                bad = bad + 1
            end
        end
    end
    check(bad == 0, "bb content aligned with pristine after crop+scale+rotate, mismatch="
        .. bad .. "/" .. n)
end)

section("repeated scaling keeps window fraction stable (v64r, no integer drift)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 裁剪窗口不在原点:cx0=30(分数 0.25);反复放大 6 轮,窗口相对原图的
    -- 分数位置不得漂移(旧实现每轮 floor(cx0·f) 取整,误差逐轮累积)
    local sx, sy = baseToScreen(el, 30, 10)
    c:_applyImageCrop(el, "nw", sx, sy)
    check(el.cx0 == 30 and el.cww == 90, "crop window 30..120")
    for _ = 1, 6 do
        c:_applyImageScale(el, { x0 = el.x, y0 = el.y,
            x1 = el.x + el.w + 25, y1 = el.y + el.h + 25 })
    end
    local frac = el.cx0 / el.cw
    check(math.abs(frac - 0.25) < 0.002,
        "window fraction stable, got " .. string.format("%.4f", frac))
    check(el.cww / el.cw > 0.74 and el.cww / el.cw < 0.76,
        "window width fraction stable, got " .. string.format("%.4f", el.cww / el.cw))
end)

section("cloned images keep own pixels across save/load (v65 metadata model)", function()
    local c = newCanvas()
    local n0 = imagesFileCount()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local elA = c.elements[1]
    check(elA.src == "/tmp/dp_img_sample.png",
        "src links original file, got " .. tostring(elA.src))
    -- 复制副本(共享 src/_orig,与 UI 复制路径同构)
    local elB = c:_cloneElement(elA)
    elB.x, elB.y = elA.x + 200, elA.y + 200
    table.insert(c.elements, elB)
    check(elB.src == elA.src and elB._bb == elA._bb, "clone shares src/bb")
    -- A 转 90°(黑半到上),B 保持左黑右白
    c:_applyImageRotate(elA, math.pi / 2)
    check(elA._bb ~= elB._bb, "transform splits bb")
    local path = "/tmp/dp_clone_project.drawing"
    check(c:_doSaveProject(path), "saved")
    -- v65:元数据模型,克隆始终共享原图 src,保存零落盘(v64w 的"各自新文件"取消)
    check(elA.src == elB.src, "clones keep shared original src")
    check(imagesFileCount() == n0, "save creates zero pixel files")
    c:_loadProject(path)
    check(#c.elements == 2, "two elements after load")
    check(imagesFileCount() == n0, "load creates zero pixel files")
    local la, lb = c.elements[1], c.elements[2]
    -- 按载入顺序识别:A 先入层(旋转后黑上白下), B(左黑右白)
    local rotA = la.rot or 0
    local aIsA = math.abs(rotA - math.pi / 2) < 0.01
    local eA = aIsA and la or lb
    local eB = aIsA and lb or la
    check(math.abs((eB.rot or 0)) < 0.01, "clone B unrotated after load")
    -- 从同一原图+各自元数据重建,像素各归各(旧实现共用一个 src 后写赢,
    -- 两边像素一样=旋转"复位")
    local ffi = require("ffi")
    local function bbpix(el, x, y)
        local s = ffi.cast("uint8_t*", el._bb.data)
        return tonumber(s[el._bb.stride * y + x])
    end
    check(bbpix(eA, math.floor(eA._bb:getWidth() / 2), 5) < 128,
        "A bb top black (rotated)")
    check(bbpix(eA, math.floor(eA._bb:getWidth() / 2), eA._bb:getHeight() - 5) > 200,
        "A bb bottom white (rotated)")
    check(bbpix(eB, 5, math.floor(eB._bb:getHeight() / 2)) < 128,
        "B bb left black (unrotated)")
    check(bbpix(eB, eB._bb:getWidth() - 5, math.floor(eB._bb:getHeight() / 2)) > 200,
        "B bb right white (unrotated)")
    -- 重载后有独立 _orig:继续编辑仍单趟重采样(不退化)
    check(eA._orig ~= nil and eB._orig ~= nil, "rebuilt pristine per element")
end)

section("crop mode body drag pans window, frame fixed (v64s)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 裁剪窗口 [30,120)x[10,90)
    local sx, sy = baseToScreen(el, 30, 10)
    c:_applyImageCrop(el, "nw", sx, sy)
    c:_cacheBBox(el)
    c:_setSelected(el)
    -- 切 crop 模式(点本体一下:scale→crop)
    c:onTap(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 } })
    check(c._handle_mode == "crop", "crop mode")
    local frame_before = { el.x, el.y, el.w, el.h }
    -- 框内拖动(向右 20):图片跟随手指 → 窗口左移 cx0 减,框固定
    c:onPan(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 },
                   start_pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 } })
    check(c._crop_pan ~= nil, "crop pan started")
    c:onPanRelease(nil, { pos = { x = el.x + el.w / 2 + 20, y = el.y + el.h / 2 } })
    check(el.x == frame_before[1] and el.y == frame_before[2]
        and el.w == frame_before[3] and el.h == frame_before[4], "frame fixed on screen")
    check(el.cx0 == 10, "window moved left (image follows finger), cx0=" .. el.cx0)
    check(el.cww == 90 and el.cwh == 80, "window size unchanged")
    -- 反向拖到头:向右拖 200 → 窗口左移钳在 0(左边界)
    c:onPan(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 },
                   start_pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 } })
    c:onPanRelease(nil, { pos = { x = el.x + el.w / 2 + 200, y = el.y + el.h / 2 } })
    check(el.cx0 == 0, "clamped at left edge, got " .. el.cx0)
    -- 撤销恢复
    c:_undo()
    check(el.cx0 == 10, "undo restores pan, got " .. el.cx0)
    c:_setSelected(el) -- undo 清选中(测试惯例)
    c:onTap(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 } }) -- scale→crop
    check(c._handle_mode == "crop", "still crop mode after undo")
    -- 框外起点拖动同样只平移窗口(v64t:裁剪框相对画布恒固定)
    c:onPan(nil, { pos = { x = el.x - 50, y = el.y - 50 },
                   start_pos = { x = el.x - 50, y = el.y - 50 } })
    check(c._crop_pan ~= nil, "outside-frame drag also pans (frame canvas-fixed)")
    c:onPanRelease(nil, { pos = { x = el.x - 30, y = el.y - 50 } })
    check(el.x == frame_before[1] and el.y == frame_before[2], "frame fixed")
    check(el.cx0 == 0, "outside drag pans window (clamped), cx0=" .. el.cx0)
    -- swipe 路径(v64t):快速滑动被 KOReader 归类成 swipe 时同样只平移窗口,
    -- 不移动对象(旧行为=_applySelectDelta 整图连框拖走="偶发框动"根因)
    -- cx0 当前 0(左钳),向左 swipe 40 → 图随手指左移 → 窗口右移钳 30
    c:onSwipe(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 },
                     end_pos = { x = el.x + el.w / 2 - 40, y = el.y + el.h / 2 } })
    check(el.x == frame_before[1] and el.y == frame_before[2],
        "swipe keeps frame fixed, got (" .. el.x .. "," .. el.y .. ")")
    check(el.cx0 == 30, "swipe pans window right (clamped), cx0=" .. el.cx0)
end)

section("rotated image occlusion stays inside frame (v64v)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_applyImageCrop(el, "se", baseToScreen(el, 60, 90)) -- 左半黑窗口
    c:_applyImageRotate(el, math.rad(30))
    -- 底层垫一条横贯画布的深色粗线(z 序在图片下):线穿过图片 AABB 顶带
    local line = {
        kind = "freehand",
        points = { { x = 0, y = el.y + 6 }, { x = c.canvas_w - 1, y = el.y + 6 } },
        width = 30, gray = 60, alpha = 255, blend = "normal", tip = "round",
    }
    table.insert(c.elements, 1, line)
    c:_cacheBBox(el)
    c:_renderAll()
    -- AABB 左上角在倾斜窗口外:应露出底层线(≈60)而非图片白角(255)
    local corner = grayAt(c, el.x + 3, el.y + 3)
    check(corner < 130, "AABB corner shows background line, got " .. corner)
    -- 窗口中心=图片内容(黑半)
    check(grayAt(c, el.x + el.w / 2, el.y + el.h / 2) < 128, "window content black")
    -- 窗口内近角(倾斜四边形内部):图片像素(黑)
    check(grayAt(c, el.x + el.w * 0.3, el.y + el.h * 0.3) < 150,
        "inside-quad pixel is image, got " .. grayAt(c, el.x + el.w * 0.3, el.y + el.h * 0.3))
end)

-- ============================ 7. 框预览(状态机) ============================

section("image frame preview scheduling", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } }) -- 选中(导入已选中则切模式,循环切回)
    for _ = 1, 3 do
        if c._handle_mode == "scale" then break end
        c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    end
    check(c._handle_mode == "scale", "scale mode")
    c:onPan(nil, { pos = { x = el.x + el.w + 4, y = el.y + el.h + 4 },
                   start_pos = { x = el.x + el.w + 4, y = el.y + el.h + 4 } })
    c:_scheduleImageFramePreview(el.x + el.w + 60, el.y + el.h + 40)
    check(c._drag_preview_pos and c._drag_preview_pos.x == el.x + el.w + 60, "preview pos recorded")
    -- 手动触发节流回调(headless 无事件循环)
    c:_flushImageFramePreview()
    check(c._drag_preview_region ~= nil, "preview region accumulated")
    c:_finishTransform(el.x + el.w + 60, el.y + el.h + 40)
    check(c._transform == nil and c._drag_preview_region == nil, "transform finished, region consumed")
end)

-- ============================ 8. 橡皮删除 ============================

section("eraser tap deletes image", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_setTool("eraser")
    c:onTap(nil, { pos = { x = el.x + 60, y = el.y + 45 } })
    check(#c.elements == 0, "image deleted by eraser tap")
    check(grayAt(c, el.x + 30, el.y + 45) > 200, "canvas restored white")
end)

-- ============================ 9. 工程保存/加载往返 ============================

section("project save/load roundtrip keeps image pixels", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 移动一下再保存(非居中位置可区分)
    c:_moveElement(el, 40, 20)
    c:_cacheBBox(el)
    c:_renderAll()
    local path = "/tmp/dp_img_project.drawing"
    check(c:_doSaveProject(path), "project saved")
    -- 同画布重载(原位清空再插入)
    c:_loadProject(path)
    check(#c.elements == 1, "one element after load")
    local el2 = c.elements[1]
    check(el2.kind == "image", "image element after load")
    check(el2._bb ~= nil, "bb reloaded from pixel copy")
    check(el2.w == 120 and el2.h == 90, "size restored")
    check(el2.x == el.x and el2.y == el.y, "position restored")
    check(grayAt(c, el2.x + 30, el2.y + 45) < 128, "dark half after reload")
    check(grayAt(c, el2.x + 90, el2.y + 45) > 200, "light half after reload")
    -- 重载后仍可选中/移动/裁剪(bb 存在)
    c:_setTool("select")
    c:_setSelected(el2)
    check(c:_hitHandle(el2.x - 4, el2.y - 4) == "nw", "handles after reload")
end)

section("transform flow creates zero pixel files, reload rebuilds from original (v65)", function()
    local c = newCanvas()
    local n0 = imagesFileCount()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    -- 裁剪:窗口 [30,120)x[10,90)
    local sx, sy = baseToScreen(el, 30, 10)
    c:_applyImageCrop(el, "nw", sx, sy)
    -- 缩放(边锚拉宽 ~1.25x,走 pristine 单趟重采样)
    local nb = { x0 = el.x, y0 = el.y, x1 = el.x + el.w * 1.25, y1 = el.y + el.h }
    c:_applyImageScale(el, nb, "e", el.x + el.w * 1.25, el.y + el.h / 2)
    -- 旋转 90°
    c:_applyImageRotate(el, math.pi / 2)
    check(imagesFileCount() == n0, "transform commits create zero files")
    local live_rot, live_cx0, live_sfx = el.rot, el.cx0, el._sfx
    local live_dark = bbDarkCount(el._bb)
    local path = "/tmp/dp_v65_project.drawing"
    check(c:_doSaveProject(path), "saved")
    check(imagesFileCount() == n0, "save creates zero files")
    check(el.sfx ~= nil and math.abs(el.sfx - live_sfx) < 0.001,
        "sfx mirrored for serialization")
    c:_loadProject(path)
    check(imagesFileCount() == n0, "load creates zero files")
    local el2 = c.elements[1]
    check(math.abs((el2.rot or 0) - live_rot) < 0.001, "rot restored")
    check(math.abs(el2.cx0 - live_cx0) < 0.02, "window restored, cx0="
        .. tostring(el2.cx0) .. " vs " .. tostring(live_cx0))
    check(el2.src == "/tmp/dp_img_sample.png", "src still original file")
    check(el2._orig ~= nil, "pristine rebuilt on load")
    -- 重建 bb 与在线 bb 黑像素一致(亚像素采样差容忍)
    local dark2 = bbDarkCount(el2._bb)
    check(math.abs(dark2 - live_dark) < math.max(8, live_dark * 0.02),
        "rebuilt pixels match live, dark " .. dark2 .. " vs " .. live_dark)
    -- 重开后再保存:仍零落盘
    check(c:_doSaveProject(path), "re-saved")
    check(imagesFileCount() == n0, "second save still zero files")
end)

section("legacy project compat: rot=0 upgraded free, rot≠0 persisted once (v65)", function()
    local c = newCanvas()
    local n0 = imagesFileCount()
    -- 旧格式 rot=0 元素(src=状态位图,无 sfx):加载即无损升级为 pristine
    local el = {
        kind = "image", src = "/tmp/dp_img_sample.png",
        x = 10, y = 10, w = 120, h = 90,
        cw = 120, ch = 90, cx0 = 0, cy0 = 0, cww = 120, cwh = 90,
    }
    check(c:_reloadImageBB(el), "legacy rot=0 reloaded")
    check(el._orig ~= nil, "rot=0 legacy upgraded to pristine")
    check(el._bb:getWidth() == 120 and el._bb:getHeight() == 90, "legacy bb dims")
    -- 旧格式 rot≠0(src=已旋转状态位图):加载保持旧语义(bb 不可从 src 重建)
    local rbb = Blitbuffer.new(90, 120, Blitbuffer.TYPE_BB8)
    rbb:paintRect(0, 0, 90, 120, Blitbuffer.COLOR_WHITE)
    rbb:paintRect(0, 0, 90, 60, Blitbuffer.COLOR_BLACK)
    rbb:writePNG("/tmp/dp_v65_legacy_rot.png")
    local el2 = {
        kind = "image", src = "/tmp/dp_v65_legacy_rot.png",
        x = 0, y = 200, w = 90, h = 120,
        cw = 120, ch = 90, cx0 = 0, cy0 = 0, cww = 120, cwh = 90,
        rot = math.pi / 2,
    }
    check(c:_reloadImageBB(el2), "legacy rot=90 reloaded")
    check(el2._orig == nil, "rot≠0 legacy stays non-rebuildable")
    table.insert(c.elements, el)
    table.insert(c.elements, el2)
    local path = "/tmp/dp_v65_legacy.drawing"
    check(c:_doSaveProject(path), "saved")
    -- 未变的旧格式元素:src 已是它的像素,不重写(跳过规则)
    check(imagesFileCount() == n0, "unchanged legacy element not rewritten")
    c:_loadProject(path)
    check(imagesFileCount() == n0, "reload creates no files")
    check(#c.elements == 2, "two elements after reload")
    local l1, l2 = c.elements[1], c.elements[2]
    local l2e = math.abs((l2.rot or 0) - math.pi / 2) < 0.01 and l2 or l1
    local l1e = (l2e == l2) and l1 or l2
    check(l1e._orig ~= nil, "upgraded element keeps pristine after reload")
    check(l2e._orig == nil, "rotated legacy element still legacy after reload")
    local ffi = require("ffi")
    local function bbpix(elx, x, y)
        local s = ffi.cast("uint8_t*", elx._bb.data)
        return tonumber(s[elx._bb.stride * y + x])
    end
    check(bbpix(l2e, math.floor(l2e._bb:getWidth() / 2), 5) < 128,
        "legacy rotated top black kept")
    check(bbpix(l2e, math.floor(l2e._bb:getWidth() / 2), l2e._bb:getHeight() - 5) > 200,
        "legacy rotated bottom white kept")
    -- 旧格式元素变换后保存:必须落盘一次像素副本(bb 已变,不可从 src 重建)
    c:_applyImageRotate(l2e, math.pi / 2)
    check(c:_doSaveProject(path), "re-saved")
    check(imagesFileCount() == n0 + 1, "transformed legacy persisted exactly once")
    check(l2e.src ~= "/tmp/dp_v65_legacy_rot.png", "legacy src repointed to pixel copy")
    -- 升级元素再变换+再保存:仍零落盘
    local before = imagesFileCount()
    c:_applyImageRotate(l1e, math.pi / 2)
    check(c:_doSaveProject(path), "re-saved 2")
    check(imagesFileCount() == before,
        "upgraded element zero files after transform+save")
    -- 再加载:旧元素 180° 后右黑左白且保持旧语义
    c:_loadProject(path)
    local m1, m2 = c.elements[1], c.elements[2]
    local m2e = math.abs((m2.rot or 0) - math.pi) < 0.01 and m2 or m1
    check(m2e._orig == nil, "legacy stays legacy after second reload")
    check(bbpix(m2e, m2e._bb:getWidth() - 5, math.floor(m2e._bb:getHeight() / 2)) < 128,
        "legacy 180deg right black kept")
    check(bbpix(m2e, 5, math.floor(m2e._bb:getHeight() / 2)) > 200,
        "legacy 180deg left white kept")
end)

section("rotate mode fast drag (swipe) commits rotation, element stays put (v65)", function()
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_sample.png")
    local el = c.elements[1]
    c:_cacheBBox(el)
    c:_setSelected(el)
    -- 切到 rotate 模式(点本体两次:scale→crop→rotate)
    local bcx = el.x + el.w / 2
    local bcy = el.y + el.h / 2
    c:onTap(nil, { pos = { x = bcx, y = bcy } })
    c:onTap(nil, { pos = { x = bcx, y = bcy } })
    check(c._handle_mode == "rotate", "rotate mode after two taps")
    local cxp, cyp = el.x + el.w / 2, el.y + el.h / 2
    -- SE 锚绕中心顺时针 90° 的终点(R(+90°) y-down: (rx,ry)→(-ry,rx))
    local rx, ry = (el.x + el.w) - bcx, (el.y + el.h) - bcy
    local ex, ey = bcx - ry, bcy + rx
    -- 路径 A:纯 swipe(快速甩动,无任何中间 pan 事件),起点直接命中锚点
    c:onSwipe(nil, { pos = { x = el.x + el.w, y = el.y + el.h },
                     end_pos = { x = ex, y = ey } })
    check(math.abs((el.rot or 0) - math.pi / 2) < 0.02,
        "swipe rotate committed 90deg, rot=" .. tostring(el.rot))
    local ncx, ncy = el.x + el.w / 2, el.y + el.h / 2
    check(math.abs(ncx - cxp) < 3 and math.abs(ncy - cyp) < 3,
        "element not dragged by swipe, center moved "
        .. tostring(ncx - cxp) .. "," .. tostring(ncy - cyp))
    -- 路径 B:pan 先启动(已锁 _transform),中途被归类为 swipe 收笔
    c:_undo() -- 回到未旋转
    check(math.abs((el.rot or 0)) < 0.01, "undo restored rot 0")
    c:_setSelected(el)
    c:onTap(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 } })
    c:onTap(nil, { pos = { x = el.x + el.w / 2, y = el.y + el.h / 2 } })
    check(c._handle_mode == "rotate", "rotate mode again")
    -- 重新计算锚点/中心(undo 后 x/y 可能微移)
    bcx = el.x + el.w / 2
    bcy = el.y + el.h / 2
    rx = (el.x + el.w) - bcx
    ry = (el.y + el.h) - bcy
    ex = bcx - ry
    ey = bcy + rx
    c:onPan(nil, { pos = { x = el.x + el.w, y = el.y + el.h },
                   start_pos = { x = el.x + el.w, y = el.y + el.h } })
    check(c._transform ~= nil, "transform latched by pan")
    c:onSwipe(nil, { pos = { x = el.x + el.w, y = el.y + el.h },
                     end_pos = { x = ex, y = ey } })
    check(math.abs((el.rot or 0) - math.pi / 2) < 0.02,
        "latched swipe rotate committed, rot=" .. tostring(el.rot))
    check(c._transform == nil, "transform cleared after finish")
end)

section("pristine upgrade from original file on upscale (v65c)", function()
    makeSamplePng("/tmp/dp_img_big.png", 1000, 750)
    local c = newCanvas()
    c:_importImageFile("/tmp/dp_img_big.png")
    local el = c.elements[1]
    local ow0, oh0 = el._orig:getWidth(), el._orig:getHeight()
    check(ow0 < 1000, "import fit downscaled, got " .. ow0)
    -- 缩小:不升级
    local nb = { x0 = el.x, y0 = el.y, x1 = el.x + el.w * 0.5, y1 = el.y + el.h }
    c:_applyImageScale(el, nb, "w", el.x + el.w * 0.5, el.y + el.h / 2)
    check(el._orig:getWidth() == ow0, "downscale keeps pristine")
    -- 1.05 微调(滞后 10% 内):不升级
    local nb2 = { x0 = el.x, y0 = el.y, x1 = el.x + el.w * 1.05, y1 = el.y + el.h }
    c:_applyImageScale(el, nb2, "e", el.x + el.w * 1.05, el.y + el.h / 2)
    check(el._orig:getWidth() == ow0, "sub-hysteresis upscale keeps pristine")
    -- 放大 2.5x:升级(从原文件按 base 尺寸重渲染),因子重定基≈1
    local nb3 = { x0 = el.x, y0 = el.y, x1 = el.x + el.w * 2.5, y1 = el.y + el.h }
    c:_applyImageScale(el, nb3, "e", el.x + el.w * 2.5, el.y + el.h / 2)
    local ow1, oh1 = el._orig:getWidth(), el._orig:getHeight()
    check(ow1 > ow0 * 1.3, "pristine upgraded to " .. ow1 .. "x" .. oh1)
    check(math.abs(el._sfx - 1) < 0.05, "re-based sfx=" .. tostring(el._sfx))
    check(math.abs(el.cw - ow1 * el._sfx) < 0.5
        and math.abs(el.ch - oh1 * el._sfy) < 0.5, "base=pristine*factor invariant")
    c:_cacheBBox(el)
    c:_renderAll()
    check(grayAt(c, el.x + 10, el.y + el.h / 2) < 128, "left dark after upgrade")
    -- 放大后元素可能超出画布(模拟器 540 宽),右侧取画布内仍在亮半区的点
    local rx = math.min(el.x + el.w - 10, c.canvas_w - 6)
    check(rx > el.x + el.w / 2, "light half partially on canvas")
    check(grayAt(c, rx, el.y + el.h / 2) > 200, "right light after upgrade")
    -- 旋转路径同样受益:rot 后再放大 1.5x,pristine 二次升级
    c:_applyImageRotate(el, math.pi / 2)
    local ow2 = el._orig:getWidth()
    c:_applyImageBaseScaleF(el, 1.5, 1.5, el.cx0 + el.cww / 2, el.cy0 + el.cwh / 2)
    check(el._orig:getWidth() > ow2 * 1.3,
        "rotated path upgrades pristine, " .. tostring(el._orig:getWidth()))
    check(math.abs((el.rot or 0) - math.pi / 2) < 0.01, "rot kept through upgrade")
    -- 存取往返:重载按 cw/sfx 渲染=与在线 pristine 同分辨率,像素一致
    local live_dark = bbDarkCount(el._bb)
    local path = "/tmp/dp_v65c_project.drawing"
    check(c:_doSaveProject(path), "saved")
    c:_loadProject(path)
    local el2 = c.elements[1]
    check(el2._orig ~= nil and el2._orig:getWidth() > ow0 * 1.3,
        "reload renders at upgraded res, " .. tostring(el2._orig and el2._orig:getWidth()))
    local dark2 = bbDarkCount(el2._bb)
    check(math.abs(dark2 - live_dark) < math.max(8, live_dark * 0.02),
        "reloaded pixels match live, dark " .. dark2 .. " vs " .. live_dark)
end)

print("image_test: ALL PASS")
