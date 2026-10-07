---
name: qt-offscreen-layout-check
description: Use when an AI agent (or anyone without the physical screen in view) changes a PyQt / Qt GUI that runs on an embedded board with a small display — render it off-screen on the board itself (QT_QPA_PLATFORM=offscreen) at the real size and fonts, save screenshots of every page and worst-case state, and measure text widths, before asking a person to look at the screen. Also for load-testing a GUI on a board with no monitor attached.
---

# 离屏渲染 Qt GUI，截图核对小屏排版

## 适用场景

- GUI 跑在板卡的小屏（如 1024×600 触摸屏）上，改布局 / 字号 / 文字的人看不到屏幕（AI 代理远程改代码，或屏幕不在手边）。
- 想确认最坏情况的文字（错误提示、长标题、不同主题）放得下，而这些状态不容易在实机上触发。
- 板子还没接显示器，想先评估 GUI 在板上的 CPU 占用和帧率。

## 使用方法

1. **在目标板上跑**，不要在 PC 上跑：字体、Qt 版本、DPI 不同，量出来的宽度没有意义。
2. `QT_QPA_PLATFORM=offscreen` 启动 GUI，`resize` 到真实屏幕尺寸，`show()` 后循环 `processEvents()` 让布局和动画走完，
   `widget.grab().save(...)` 截图。模板见本目录 `offscreen_shots.py`。
3. **逐状态截图**：每个标签页、每个主题、每个弹出 / 放大视图、动画的几个关键时刻（按时间点截）。
4. **量而不是猜**：用 `QFontMetrics.horizontalAdvance()` 量最坏情况文字的像素宽度，和控件宽度比。
5. 把截图拷回 PC 看（AI 代理可以直接读图），确认无误后再请人上实机操作；实机只需要确认触摸和交互。
6. 压测：offscreen 模式下 GUI 照常接收实时数据，统计每帧绘图耗时和 CPU 占用，决定是否需要精简模式。

注意：离屏渲染不能代替触摸交互和实际显示效果（亮度、色彩、反光），也不能发现 GPU / X 相关的问题。

## 已验证效果

- 本项目 RX 板 GUI：介绍页 6 个主题、彩蛋动画 6 帧、错误标题等都先离屏截图核对，再部署上屏；"CRC 错误 / 解码失败"标题超宽问题
  用板上字体离屏量宽后修正，这两种状态无需真的制造链路故障。脚本：`src/sw/tools/about_shots.py`、`clawd_shots.py`。
- 未接显示器时用 offscreen 模式在 RX 板上压测：原样的 PC 版 GUI 在板上带不动，据此做了 `--lite` 精简模式（约占单核 78%），接屏后实测约 85%。

## 来源（从哪次失败中总结）

GUI 在 1024×600 小屏上多次出现 AI 改完、人一看才发现的问题：星座图太挤、文字偏小、RX 图像标题在出错状态下超出范围、正常状态显示出 `&nbsp`。
每次都要参赛者看屏、拍照、描述，往返代价高。改为先在板上离屏渲染逐页自查，人只做最后的实机确认。
