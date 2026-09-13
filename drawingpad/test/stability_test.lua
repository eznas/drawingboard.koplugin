--[[--
绘图板稳定性单测(死机修复项):
1. 定时任务:scheduleIn 返回 nil 取不到句柄 → 保存闭包引用、unschedule 按引用取消;
   图形拖动期间预览定时器不堆积(旧的堆积曾导致设备上同秒 40+ 条 preview shown);
   关闭/切工具后任务从队列移除,关闭后手动触发挂起回调也不报错
2. 元素 bbox 缓存:提交后 el._bbox 存在且与 _elementBBox 一致;点删预过滤后仍能命中
3. 区域化重绘:删上层笔画后,重叠区恢复底层墨迹、仅上层处变白(像素断言)
4. 笔画抽稀:10000 点 → 4096 且保首尾;最小步距削减 1px 密集点
5. 文字 nil face 防护:字体缺失不抛错、文字元素仍提交
6. 保存:_nextSavePath 同秒加序号;_doSave 真实生成 PNG(magic 校验)

运行(从 KOReader 根目录):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/stability_test.lua
--]]

-- 绘图板模块已随插件移入 plugins/drawingboard.koplugin/drawingpad/:
-- 测试不经 pluginloader,自定位插件根注入 package.path,使 require("drawingpad.*") 可解析
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")

-- 前置初始化必须早于任何 require("ui/uimanager")/require("device")
-- (sdl 设备模块加载期就会访问 G_reader_settings,顺序与 render_test 保持一致)
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _inited = false
local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

-- ============ 1. 定时任务:闭包引用取消 + 不堆积 ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local orig_scheduleIn = UIManager.scheduleIn
        local orig_unschedule = UIManager.unschedule
        local queue = {}
        local scheduled, unscheduled = 0, 0
        -- 模拟真实行为:scheduleIn 无 return(返回 nil);unschedule 按闭包引用移除
        UIManager.scheduleIn = function(self, seconds, action)
            scheduled = scheduled + 1
            table.insert(queue, action)
            return nil
        end
        UIManager.unschedule = function(self, action)
            local removed = false
            for i = #queue, 1, -1 do
                if queue[i] == action then
                    table.remove(queue, i)
                    removed = true
                    unscheduled = unscheduled + 1
                end
            end
            return removed
        end

        local canvas = newCanvas()
        canvas:_setTool("circle")
        -- 连续拖动 5 个 pan:每次取消上一个预览定时器再重排 → 队列始终只有 1 个
        for i = 1, 5 do
            canvas:_trackShapeAnchor({ pos = { x = 100 + i * 10, y = 300 }, start_pos = { x = 100, y = 300 } })
        end
        check(#queue == 1, "shape preview tasks should not accumulate, got " .. #queue)
        check(scheduled == 5 and unscheduled == 4,
            "expect 5 scheduled / 4 cancelled, got " .. scheduled .. "/" .. unscheduled)
        -- 关闭:挂起任务从队列移除(旧版无法取消,关闭后仍触发)
        canvas:onCloseWidget()
        check(#queue == 0, "close should remove pending tasks, got " .. #queue)

        -- 画笔节流:连续扩展只排 1 个任务;切工具后取消
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 150, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(#queue == 1, "stroke repaint should have 1 pending task, got " .. #queue)
        canvas2:_setTool("eraser")
        check(#queue == 0, "tool switch should cancel stroke repaint, got " .. #queue)
        -- 关闭后手动触发挂起回调(极端情况兜底):不报错
        canvas2:onCloseWidget()
        local ok_cb = pcall(function()
            canvas2:_flushStrokeRepaint()
            canvas2:_maybeShowShapePreview()
        end)
        check(ok_cb, "callbacks after close should not throw")

        UIManager.scheduleIn = orig_scheduleIn
        UIManager.unschedule = orig_unschedule
    end)
    if ok then
        print("PASS: timer cancel-by-closure (no accumulation, close/tool-switch cancels)")
    else
        print("FAIL: timer cancel-by-closure:", tostring(err))
        os.exit(1)
    end
end

-- ============ 2. 元素 bbox 缓存 ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 220, y = 360 } })
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 300, y = 300 }, end_pos = { x = 380, y = 360 } })
        canvas:_commitText(400, 300, "测试")
        check(#canvas.elements == 3, "setup elements, got " .. #canvas.elements)
        for _, el in ipairs(canvas.elements) do
            check(el._bbox ~= nil, "element missing _bbox: " .. tostring(el.kind))
            local b = canvas:_elementBBox(el)
            check(b and b.x0 == el._bbox.x0 and b.y0 == el._bbox.y0
                and b.x1 == el._bbox.x1 and b.y1 == el._bbox.y1,
                "cached bbox mismatch for " .. tostring(el.kind))
        end
        -- bbox 预过滤后点删仍能命中(收笔点 (220,360))
        canvas:_setTool("eraser")
        local hit = canvas:_eraseAt(220, 360)
        check(hit and #canvas.elements == 2, "eraseAt after bbox cache failed")
        print("bbox: 3 elements cached & consistent, eraseAt hit OK")
    end)
    if ok then
        print("PASS: element bbox cache")
    else
        print("FAIL: element bbox cache:", tostring(err))
        os.exit(1)
    end
end

-- ============ 3. 区域化重绘:像素断言 ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas.width = 12
        -- 底层笔画 A:y=300,黑色(灰 1.0)
        canvas.gray = 1.0
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 400, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 400, y = 300 } })
        -- 上层笔画 B:y=305,中灰(灰 0.5)
        canvas.gray = 0.5
        canvas:onPan(nil, { pos = { x = 100, y = 305 }, start_pos = { x = 100, y = 305 } })
        canvas:onPan(nil, { pos = { x = 400, y = 305 }, start_pos = { x = 100, y = 305 } })
        canvas:onPanRelease(nil, { pos = { x = 400, y = 305 } })
        check(#canvas.elements == 2, "setup two strokes, got " .. #canvas.elements)
        local bb = canvas.canvas_bb
        local function a(y) return bb:getPixel(250, y) and bb:getPixel(250, y).a end
        -- 删除前:重叠区(302)=B 的灰,B 独有区(308)=B 灰,A 独有区(295)=黑
        check(a(302) ~= 255 and a(302) ~= 0, "before: overlap should be B gray, got " .. tostring(a(302)))
        check(a(308) ~= 255 and a(308) ~= 0, "before: B-only should be gray, got " .. tostring(a(308)))
        check(a(295) == 0, "before: A-only should be black, got " .. tostring(a(295)))
        -- 点 (250,308) 只落在 B 的墨迹上 → 删 B(保留 A)
        canvas:_setTool("eraser")
        local hit = canvas:_eraseAt(250, 308)
        check(hit, "eraseAt should hit top stroke")
        check(#canvas.elements == 1, "should delete top stroke, got " .. #canvas.elements)
        -- 删除后:B 独有区变白;重叠区恢复为底层 A 的黑色;A 独有区仍是黑
        check(a(308) == 255, "after: B-only should be white, got " .. tostring(a(308)))
        check(a(302) == 0, "after: overlap should restore bottom ink (black), got " .. tostring(a(302)))
        check(a(295) == 0, "after: A-only should still be black, got " .. tostring(a(295)))
        -- 撤销:恢复 B,重叠区回到 B 灰
        canvas:_undo()
        check(#canvas.elements == 2, "undo should restore B")
        check(a(302) ~= 255 and a(302) ~= 0, "undo: overlap should be B gray again, got " .. tostring(a(302)))
        -- 重做:再删 B
        canvas:_redo()
        check(#canvas.elements == 1, "redo should delete B again")
        check(a(308) == 255 and a(302) == 0, "redo: B-only white, overlap black")
        print("redrawRegion pixels: overlap restores bottom ink, B-only clears, undo/redo consistent")
    end)
    if ok then
        print("PASS: region-limited redraw (pixels)")
    else
        print("FAIL: region-limited redraw:", tostring(err))
        os.exit(1)
    end
end

-- ============ 4. 笔画抽稀 + 最小步距 ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        local pts = {}
        for i = 1, 10000 do
            pts[i] = { x = i, y = math.floor(i / 10) }
        end
        local out = canvas:_thinPoints(pts)
        check(#out == 4096, "thin should cap at 4096, got " .. #out)
        check(out[1].x == 1 and out[#out].x == 10000, "thin should keep first/last")

        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2.width = 32 -- min_step = floor(32/8) = 4
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        for i = 101, 200 do -- 1px 步进 100 次
            canvas2:onPan(nil, { pos = { x = i, y = 300 }, start_pos = { x = 100, y = 300 } })
        end
        canvas2:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        local s = canvas2.elements[1]
        check(s ~= nil and s.kind == "freehand", "stroke should commit")
        check(#s.points < 50, "min_step should cut dense points, got " .. #s.points)
        check(s.points[1].x == 100 and s.points[#s.points].x == 200, "first/last kept")
        print(string.format("thin: 10000->4096 first/last kept; min_step: 100 1px-steps -> %d points", #s.points))
    end)
    if ok then
        print("PASS: stroke thinning + min step")
    else
        print("FAIL: stroke thinning:", tostring(err))
        os.exit(1)
    end
end

-- ============ 5. 文字 nil face 防护 ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        -- 不存在的字体:getFace 返回 nil,_drawTextTo 应跳过而非抛错
        local ok1 = pcall(function()
            canvas:_drawTextTo(canvas.canvas_bb, {
                kind = "text", x = 10, y = 30, text = "abc",
                font = "no_such_font_xyz.ttf", size = 24, gray = 1.0,
            })
        end)
        check(ok1, "_drawTextTo with missing font should not throw")
        -- 文字提交路径(对话框按钮回调触发,已被 wrapHandler 包 pcall):字体缺失也不崩,
        -- 文字元素照常提交(绘制被跳过)
        canvas.font = "no_such_font_xyz.ttf"
        local ok2 = pcall(function()
            canvas:_commitText(50, 50, "缺失字体测试")
        end)
        check(ok2, "_commitText with missing font should not throw")
        check(#canvas.elements == 1 and canvas.elements[1].kind == "text",
            "text element should still commit")
        print("text nil-face guard OK (draw skipped, commit kept)")
    end)
    if ok then
        print("PASS: text missing-font guard")
    else
        print("FAIL: text missing-font guard:", tostring(err))
        os.exit(1)
    end
end

-- ============ 6. 保存:同秒序号 + 真实 PNG ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 220, y = 360 } })
        local lfs = require("libs/libkoreader-lfs")
        local dir = "/tmp/drawingpad_save_test"
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        -- 重名序号:预置同名文件,下一次应得 _2
        local fname = "drawing_20260815_120000.png"
        local first = dir .. "/" .. fname
        local f = io.open(first, "wb")
        f:write("dummy")
        f:close()
        local p1 = canvas:_nextSavePath(dir, lfs, fname)
        check(p1 == dir .. "/drawing_20260815_120000_2.png",
            "same-name collision should get _2, got " .. p1)
        -- 真实保存:PNG magic 校验
        local target = dir .. "/drawing_real.png"
        local saved = canvas:_doSave(target)
        check(saved == target, "_doSave should return the path")
        local mf = io.open(saved, "rb")
        local magic = mf and mf:read(8)
        if mf then mf:close() end
        local expected = string.char(137, 80, 78, 71, 13, 10, 26, 10)
        check(magic == expected, "saved PNG magic mismatch")
        -- 保存分辨率 = 画布(设备屏幕)分辨率,不裁剪白边
        local mf2 = io.open(saved, "rb")
        local hdr = mf2 and mf2:read(24)
        if mf2 then mf2:close() end
        if hdr and #hdr >= 24 then
            local w = hdr:byte(17) * 16777216 + hdr:byte(18) * 65536 + hdr:byte(19) * 256 + hdr:byte(20)
            local h = hdr:byte(21) * 16777216 + hdr:byte(22) * 65536 + hdr:byte(23) * 256 + hdr:byte(24)
            check(w == canvas.canvas_w and h == canvas.canvas_h,
                string.format("saved PNG %dx%d should match screen %dx%d", w, h, canvas.canvas_w, canvas.canvas_h))
        else
            print("WARN: cannot read PNG dimensions, skip resolution assertion")
        end
        local crop = canvas:_contentBBox()
        check(crop ~= nil, "contentBBox should find content")
        -- 清理
        os.remove(first)
        os.remove(saved)
        print(string.format("save: same-second numbering + PNG magic OK (crop %dx%d)", crop.w, crop.h))
    end)
    if ok then
        print("PASS: save flow")
    else
        print("FAIL: save flow:", tostring(err))
        os.exit(1)
    end
end

print("ALL STABILITY TESTS PASSED")
os.exit(0)
