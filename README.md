# 绘图板 Drawingboard

KOReader 画板插件 —— 在电纸书阅读器上画画、记笔记。

在 Kindle / 其他 e-ink 设备的 KOReader 中提供一块全屏画布:7 种笔触(钢笔/铅笔/马克笔等)、几何图形(直线/矩形/椭圆/实心图形,支持旋转)、文字、橡皮删除对象、选中对象移动/复制/缩放/旋转(锚点)、3 个图层与显隐切换、撤销/重做,作品可保存为 PNG,工程可保存/打开(.drawing)。

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
- **墨水屏刷新优化**:局部刷新、合并/限区域/节流,回放收尾可交还画板继续编辑

## 测试

`drawingpad/test/` 内为模拟器(headless wbuilder)自检脚本,可用 `lua` 直接运行,例如:

```sh
lua drawingpad/test/feature_test.lua
```

## 许可

本项目以 [AGPL-3.0](LICENSE) 发布。

致谢:

- [KOReader](https://github.com/koreader/koreader) —— 插件运行平台;`drawingpad/icons/appbar.menu.svg` 与 `drawingpad/icons/cre.render.reload.svg` 取自 KOReader 官方图标集(AGPL-3.0),其余图标为本项目自制
