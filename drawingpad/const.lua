--[[--
drawingpad.const — 绘图板常量与纯工具函数(无 UI 依赖)。
各功能模块 require 本文件取常量;pointSegDist 供墨迹距离计算。
--]]

-- 调试日志总开关:开发期置 true;发布置 false(零 IO 省电)
local LOG_ENABLED = false

-- 图形工具手指停留显示预览的延迟(秒)
local SHAPE_PREVIEW_DELAY = 0.12

-- 选择工具 移动/复制/旋转 拖拽:手指停留满该延迟后,在当前位置显示落点/变形预览
-- (停止位置防抖;0.2s 保证反馈跟手,仍能滤掉连续拖动;v61r 文字对象同样统一 0.2s)
local MOVE_PREVIEW_DELAY = 0.2

-- 拖拽预览跟随刷新节流间隔(px/秒):预览出现后每次 pan 更新预览元素,
-- 屏幕按窗口合并区域刷新(与笔画节流同量级,墨水屏波形有上限,防排队卡顿;
-- 收笔时立即补一次)。微动不重绘由 _updateDragPreview 的 bbox 去重保证
local DRAG_PREVIEW_REFRESH_INTERVAL = 0.06

-- 旋转预览重建节流角度(弧度):预览跟随期间手指每次移动都全量重栅格化选中对象
-- (fill 数百行 span 旋转一次数毫秒到数百毫秒),角度变化小于该阈值跳过重建,
-- 只更新落点位置——重栅格化频率降到 repaint 节流同量级,拖拽旋转不再卡断
local DRAG_ROTATE_RECALC_ANGLE = 0.03

-- 笔画刷新节流间隔(秒):墨水屏波形更新有上限,逐 pan 事件刷新会排队滞后(卡顿);
-- 窗口内只排一次重绘并合并刷新区域,收笔时立即补一次刷新
-- 粗笔画(线宽 ≥ THICK_WIDTH)刷新区域大、压力高,节流间隔再放宽以减少波形刷新次数
local STROKE_REFRESH_INTERVAL = 0.06
local THICK_WIDTH = 32
local THICK_REFRESH_INTERVAL = 0.1

-- 橡皮点选容差(px):点击点离最近墨迹超过该距离视为点空白,不删除
local PICK_TOLERANCE = 20

-- 填充工具:洪泛填充颜色容差(0-255 像素值差)。容差必须足够小,浅色描边
-- (灰 ≥0.08,像素值 ≤229)与白背景差 >20 才能被识别为边界,否则填充穿透浅色描边溢出
local FILL_TOLERANCE = 20
-- 填充边缘检测容差:展开到相邻像素时,两像素局部差值 > 该值即视为边界。
-- 与"与种子色差值"无关——浅色描边(灰 5%~9%,像素值 232~242)与白背景差 >8
-- 即成边界,彻底摆脱固定容差漏掉更浅描边的天花板
local FILL_EDGE_TOLERANCE = 8

-- 变形锚点:命中半径(px)。锚点视觉小巧(缩放方块 12px / 旋转圆点 10px)不遮挡画面,
-- 命中半径 48 远大于视觉,便于手指准确点中;再次点选选中对象在 四角缩放/四角旋转 间切换
local HANDLE_HIT_RADIUS = 48

-- 文字锚点命中半径(px):文字选取框小、更难点中,命中范围更大
local TEXT_HANDLE_HIT_RADIUS = 64

-- 起笔死区调优(v56):KOReader 手势检测在按下后要移够 PAN_THRESHOLD(scaleByDPI(35),
-- PW3 约 44px / 模拟器约 33px)才发第一个 pan 事件——起笔段的弧线信息在死区内
-- 从源头丢失(插件收不到任何中间点),这是"起笔不能画曲线"的主因。
-- 画板打开期间把手势检测实例的 PAN_THRESHOLD 动态调低到 scaleByDPI(该值),
-- 关闭时还原:不改 KOReader 源码,不影响画板以外的手势行为。
-- 值越小起笔越跟手;过小(<8)会让点按的轻微漂移误判成 pan(轻触变拖动)
local GESTURE_PAN_THRESHOLD_DP = 10

-- 起笔停留延迟调优(v56b):画板期间把手势检测的 hold 定时间隔按比例缩短。
-- KOReader 默认 HOLD_INTERVAL_MS=500:手不动满该时长才发 hold(起笔停留此时才出
-- 圆点、之后 hold_pan 才跟手),慢起笔要白等这段。缩到 300ms 慢起笔更早出墨。
-- 用比例缩放(新值/500)实现,不依赖 time 模块与单位,用户自设的间隔同比例缩短。
-- 副作用:工具栏长按切换变灵敏——落笔到抬笔慢于该间隔的点按会被判成长按,
-- 触发次要功能(切到 [重做]/[清空] 等模式);若常误触,调回 350~400
local GESTURE_HOLD_INTERVAL_MS = 300

-- 起笔防抖拆成两个阶段(v56,起笔曲线优化):
-- ① STROKE_EARLY_TRIGGER_DIST:按下后移动超过该距离就正式起笔(转进行中笔画)。
-- 值越小起笔越早,起笔处的小圆弧越早进入 Catmull-Rom 渲染而保留曲率;
-- 设 0 = 第一个 pan 点到达即起笔(跟手最紧,但快速轻触会起一笔)。
-- ② STROKE_DEBOUNCE_DIST:微轨迹起记阈值(px)。阈值内的微小移动也记入微轨迹,
-- 起笔时作为完整起始路径渲染;防抖期松手且有微轨迹时按完整弧提交短笔画。
-- 两者分离:微轨迹早记(保住弧线信息),起笔按独立阈值触发(兼顾起笔抖动)
local STROKE_EARLY_TRIGGER_DIST = 1
local STROKE_DEBOUNCE_DIST = 1

-- 防抖:形状落笔最小尺寸(px)。直线长度/矩形最大边/圆半径小于该值视为误触丢弃
-- (随笔宽放大:粗笔误触的尺寸阈值更大)
local SHAPE_MIN_SIZE = 8

-- 撤销栈上限:超过后丢弃最旧记录,防止长时间绘画内存无限增长
local UNDO_LIMIT = 100

-- 单笔点数上限:超过后收笔时均匀抽稀(保首尾)。慢笔画/长时间连续画会产生大量
-- 1px 内的密集点,收敛后单笔内存与橡皮/保存的扫描成本都有限,长会话不再线性放大
local MAX_STROKE_POINTS = 4096

-- 工具设置持久化键:退出时写入插件目录(drawingpad_settings.lua),下次打开自动读取。
-- 只持久化"绘画参数"类设置(灰度/粗细/笔触/字体/字号/保存目录):
-- 菜单/按钮状态类设置(实心/空心、橡皮模式、选择移动/复制、撤销/重做、刷新/清空)
-- 不持久化,每次启动恢复默认 = 工具栏白底黑字的主要功能态。
-- "last_text"(上次文字内容)字段带下划线,在 actions.lua 存取设置时单独处理
local SETTING_KEYS = {
    "gray", "gray_min", "gray_max", "gray_levels", "gray_random",
    "width", "width_min", "width_max", "width_levels", "width_random",
    "alpha", "alpha_min", "alpha_max", "alpha_levels", "alpha_random",
    "tip", "save_folder",
    "font", "font_size",
    "menu_lang",
}

-- v62n:界面名称表统一英文源(中文经 i18n dict 查表,与 plugin_manager 同套路)
local TOOL_NAMES = {
    brush = "Brush",
    eraser = "Eraser",
    line = "Line",
    rect = "Rect",
    circle = "Ellipse",
    text = "Text",
    select = "Select",
    fill = "Fill",
}

-- 图层数:v57 起从硬编码 3 改为常量,便于以后扩展(命名槽位/锁定等)。
-- 改 LAYER_COUNT 后还需确认 layers.lua 的 `((n-1) % 3) + 1` 取模公式与 drawing_canvas
-- 的 layers={} 初始化数组长度(本常量未直接用到此处,但下游可读为单一真理源)。
local LAYER_COUNT = 3

-- 插件版本与作者(关于弹窗,2026-09-03 v59e)
local PLUGIN_VERSION = "v62s"
local PLUGIN_AUTHOR = "eznas"

-- 图层命名:索引 1=下层(最先绘制,最底) 2=中层 3=上层(最后绘制,最顶);
-- 遮挡关系按命名:上层盖中层、中层盖下层
local LAYER_NAMES = { [1] = "bottom", [2] = "middle", [3] = "top" }

-- 笔触形状(仅画笔/直线):内部名 → 状态栏缩写
local TIP_NAMES = {
    circle = "O",
    square = "S",
    triangle = "T",
    triangle_inv = "V",
    diamond = "D",
    slash = "/",
    backslash = "\\",
}
-- 笔触菜单条目(内部名,显示名)
local TIPS = {
    { "circle", "Ellipse" },
    { "square", "Square" },
    { "triangle", "Triangle" },
    { "triangle_inv", "Inv tri" },
    { "diamond", "Diamond" },
    { "slash", "Slash" },
    { "backslash", "Backslash" },
}

-- ============================ 界面统一常量(v59) ============================

-- UI 灰值三档(墨水屏灰阶统一,避免各处魔法数):
-- BAR = 状态栏底色;HIGHLIGHT = 画布选中框/变形锚点共用高亮灰;
-- 面板激活底色用 Blitbuffer.COLOR_LIGHT_GRAY(标准浅灰,不在此定义)
local UI_GRAY_BAR = 0.5
local UI_GRAY_HIGHLIGHT = 0.25

-- 弹窗宽度档(屏宽比例):窄 = 单列菜单(图层/笔触行),中 = 分类面板与双列设置弹窗,
-- 宽 = 滑条/文件夹浏览器/字体列表
local UI_WIDTH_NARROW = 0.3
local UI_WIDTH_MEDIUM = 0.5
local UI_WIDTH_WIDE = 0.85

-- 底栏一级入口图标(mdlight 图标库名,IconWidget 按名解析)。
-- v59b:取消长按后,刷新从功能面板提升为一级入口;
-- v59c:隐藏(最小化)移到最左,取消一级保存(功能面板已有);
-- v59d:退出并入功能面板,新增一级图层入口,功能固定最右
-- v59e:全套统一 mdlight 线框风(48 网格 stroke 1.8);v61i:自带图标改为
--   drawingpad/icons/ 下的资源文件(menus.lua 首运行装入用户 icons 目录),
--   mdlight 缺的(layers/上下箭头)与旧版设备构建缺的(appbar.menu/cre.render.reload)都在其中
-- 底栏/恢复按钮图标边长(scaleBySize 前的基准像素;40 偏大,34 约缩 15%)
local TOOLBAR_ICON_PX = 34

local TOOLBAR_ICONS = {
    { id = "hide_btn",    icon = "dw.chevron.down" },
    -- v61m:工具改用 dw.edit(自带 edit 缩小 10%,原满幅实心视觉偏大,不覆写全局 edit)
    { id = "cat_tool",    icon = "dw.edit" },
    { id = "cat_prop",    icon = "appbar.settings" },
    { id = "cat_layer",   icon = "layers" },
    { id = "refresh_btn", icon = "cre.render.reload" },
    { id = "cat_func",    icon = "appbar.menu" },
}

-- 点到线段的最短距离
local function pointSegDist(px, py, x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local len2 = dx * dx + dy * dy
    if len2 < 0.001 then
        return math.sqrt((px - x0) ^ 2 + (py - y0) ^ 2)
    end
    local t = ((px - x0) * dx + (py - y0) * dy) / len2
    t = math.max(0, math.min(1, t))
    local cx, cy = x0 + dx * t, y0 + dy * t
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

return {
    LOG_ENABLED = LOG_ENABLED,
    SHAPE_PREVIEW_DELAY = SHAPE_PREVIEW_DELAY,
    MOVE_PREVIEW_DELAY = MOVE_PREVIEW_DELAY,
    DRAG_PREVIEW_REFRESH_INTERVAL = DRAG_PREVIEW_REFRESH_INTERVAL,
    DRAG_ROTATE_RECALC_ANGLE = DRAG_ROTATE_RECALC_ANGLE,
    STROKE_REFRESH_INTERVAL = STROKE_REFRESH_INTERVAL,
    THICK_WIDTH = THICK_WIDTH,
    THICK_REFRESH_INTERVAL = THICK_REFRESH_INTERVAL,
    PICK_TOLERANCE = PICK_TOLERANCE,
    FILL_TOLERANCE = FILL_TOLERANCE,
    FILL_EDGE_TOLERANCE = FILL_EDGE_TOLERANCE,
    HANDLE_HIT_RADIUS = HANDLE_HIT_RADIUS,
    TEXT_HANDLE_HIT_RADIUS = TEXT_HANDLE_HIT_RADIUS,
    STROKE_EARLY_TRIGGER_DIST = STROKE_EARLY_TRIGGER_DIST,
    STROKE_DEBOUNCE_DIST = STROKE_DEBOUNCE_DIST,
    GESTURE_PAN_THRESHOLD_DP = GESTURE_PAN_THRESHOLD_DP,
    GESTURE_HOLD_INTERVAL_MS = GESTURE_HOLD_INTERVAL_MS,
    SHAPE_MIN_SIZE = SHAPE_MIN_SIZE,
    UNDO_LIMIT = UNDO_LIMIT,
    MAX_STROKE_POINTS = MAX_STROKE_POINTS,
    LAYER_COUNT = LAYER_COUNT,
    PLUGIN_VERSION = PLUGIN_VERSION,
    PLUGIN_AUTHOR = PLUGIN_AUTHOR,
    SETTING_KEYS = SETTING_KEYS,
    TOOL_NAMES = TOOL_NAMES,
    LAYER_NAMES = LAYER_NAMES,
    TIP_NAMES = TIP_NAMES,
    TIPS = TIPS,
    UI_GRAY_BAR = UI_GRAY_BAR,
    UI_GRAY_HIGHLIGHT = UI_GRAY_HIGHLIGHT,
    UI_WIDTH_NARROW = UI_WIDTH_NARROW,
    UI_WIDTH_MEDIUM = UI_WIDTH_MEDIUM,
    UI_WIDTH_WIDE = UI_WIDTH_WIDE,
    TOOLBAR_ICONS = TOOLBAR_ICONS,
    TOOLBAR_ICON_PX = TOOLBAR_ICON_PX,
    pointSegDist = pointSegDist,
}
