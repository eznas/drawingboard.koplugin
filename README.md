# Drawingboard for KOReader

A drawing pad for KOReader — sketch and take notes on your e-reader.

Drawingboard adds a fullscreen canvas to KOReader on Kindle and other e-ink devices: 7 brush types (pen / pencil / marker and more), geometric shapes (lines, rectangles, ellipses, solid fills — rotatable), text, object-based erasing, and selection with move / copy / scale / rotate (anchor handles), across 3 layers with visibility toggles and full undo/redo. Artwork can be exported as PNG; projects can be saved and reopened (`.drawing`).

It also doubles as an **e-ink wallpaper generator**: sketch a pattern or illustration, export it as PNG, and set it as your device's sleep screen — no computer needed, fully offline.

Refresh behaviour is tuned for e-ink: partial refreshes with region merging and throttling avoid full-screen flashes and ghosting. It also works around real-device quirks such as Kindle startup-script restart loops and framebuffer contention.

The plugin appears as **Drawing Board** (or **绘图板** on Chinese-language systems) in the KOReader menu.

## Screenshots

![Drawing board UI](docs/screenshot.png)

A grayscale artwork drawn with the drawing board:

![Grayscale artwork example](docs/artwork_hulk.png)

## Features

- **Brushes**: 7 stroke types, adjustable width, secondary stroke smoothing
- **Shapes**: lines / rectangles / ellipses / solid fills, rotatable (solid shapes recompute their vertices, no self-overlap)
- **Text**: insert anywhere; scales with its object
- **Selection & transforms**: move / copy / scale / rotate selected objects with anchor control
- **Layers**: 3 layers with per-layer visibility and occlusion
- **Undo/redo**, clear canvas, export PNG, save/open `.drawing` projects
- **Wallpaper-ready**: exports are plain PNG — use your own artwork as the device's sleep screen / wallpaper
- **E-ink refresh optimization**: partial refreshes, region merging / limiting / throttling; after a playback finish, control is handed back to the canvas for further editing

## Installation

- **Option 1 (recommended)**: download the latest zip from [Releases](https://github.com/eznas/drawingboard.koplugin/releases), extract it, and copy the whole `drawingboard.koplugin/` folder into your device's KOReader plugins directory (`koreader/plugins/` on Kindle). Restart KOReader and you are done.
- **Option 2**: clone this repository into the same plugins directory (the `drawingpad/test/` folder is only used by headless self-tests and can be deleted):

  ```sh
  git clone https://github.com/eznas/drawingboard.koplugin.git
  ```

## Compatibility

Developed and tested on **Kindle** running recent KOReader releases (2026). The plugin uses only standard KOReader APIs and no device-specific features at runtime, so it should work wherever KOReader runs — but other devices (BOOX, Kobo, PocketBook, desktop) are untested so far. Issue reports from other platforms are welcome.

## Self-tests

`drawingpad/test/` contains headless (wbuilder) self-test scripts that run with plain `lua`, for example:

```sh
lua drawingpad/test/feature_test.lua
```

## Licence

Released under the [AGPL-3.0](LICENSE), the same licence as KOReader.

Acknowledgements:

- [KOReader](https://github.com/koreader/koreader) — the platform this plugin runs on; `drawingpad/icons/appbar.menu.svg` and `drawingpad/icons/cre.render.reload.svg` are taken from the official KOReader icon set (AGPL-3.0). All other icons are original.

---

# 绘图板 Drawingboard（中文）

KOReader 画板插件 —— 在电纸书阅读器上画画、记笔记。

在 Kindle / 其他 e-ink 设备的 KOReader 中提供一块全屏画布:7 种笔触(钢笔/铅笔/马克笔等)、几何图形(直线/矩形/椭圆/实心图形,支持旋转)、文字、橡皮删除对象、选中对象移动/复制/缩放/旋转(锚点)、3 个图层与显隐切换、撤销/重做,作品可保存为 PNG,工程可保存/打开(.drawing)。

它同时也是一个**墨水屏壁纸生成器**:随手画个图案或小插画,导出 PNG 即可设为设备待机画面 —— 不需要电脑,全程离线。

针对墨水屏做了专门的刷新优化:局部刷新、区域合并与节流,避免整屏闪烁和残影;对真机上 KOReader 的启动脚本重启循环、帧缓冲争用等环境问题做了兼容处理。

## 界面与作品

![绘图板界面](docs/screenshot.png)

用绘图板绘制的灰度作品:

![灰度作品示例](docs/artwork_hulk.png)

## 安装

- **方式一(推荐)**:到 [Releases](https://github.com/eznas/drawingboard.koplugin/releases) 下载最新 zip,解压后把 `drawingboard.koplugin/` 整个文件夹放入设备的 KOReader 插件目录(Kindle 为 `koreader/plugins/`),重启 KOReader 即可。
- **方式二**:克隆本仓库(测试目录 `test/` 对插件运行无影响,可自行删除):

  ```sh
  git clone https://github.com/eznas/drawingboard.koplugin.git
  ```

## 功能

- **画笔**:7 种笔触,勾线粗细可调,墨迹二次平滑
- **图形**:直线/矩形/椭圆/实心填充,支持旋转(实心图形按顶点重算,不穿模)
- **文字**:任意位置输入,随对象缩放
- **选择与变形**:框选对象后移动/复制/缩放/旋转,锚点控制
- **图层**:3 层,支持显隐切换与遮挡
- **撤销/重做**,清空,保存 PNG,工程保存/打开(.drawing)
- **壁纸即产物**:导出的 PNG 直接可用 —— 把自己画的作品设为待机壁纸/屏保
- **墨水屏刷新优化**:局部刷新、合并/限区域/节流,回放收尾可交还画板继续编辑

## 兼容性

在 **Kindle**(2026 年近期 KOReader 版本)上开发并真机测试。插件只使用 KOReader 标准 API,运行时不依赖设备专属特性,理论上可在任何 KOReader 支持的设备上运行;其他设备(BOOX、Kobo、PocketBook、桌面端)暂未实测,欢迎反馈 issue。

## 测试

`drawingpad/test/` 内为模拟器(headless wbuilder)自检脚本,可用 `lua` 直接运行,例如:

```sh
lua drawingpad/test/feature_test.lua
```

## 许可

本项目以 [AGPL-3.0](LICENSE) 发布。

致谢:

- [KOReader](https://github.com/koreader/koreader) —— 插件运行平台;`drawingpad/icons/appbar.menu.svg` 与 `drawingpad/icons/cre.render.reload.svg` 取自 KOReader 官方图标集(AGPL-3.0),其余图标为本项目自制
