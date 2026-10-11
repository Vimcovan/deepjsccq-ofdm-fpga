---
name: touch-without-multitouch
description: Use when a multi-touch USB touch screen on PYNQ (or another embedded Linux image whose kernel lacks CONFIG_HID_MULTITOUCH) only produces instant taps in X / Qt — press-and-hold and drag do not work. Diagnose from evdev and read the finger position directly, without rebuilding the kernel.
---

# 内核缺 hid-multitouch 时的触摸屏长按 / 拖动补救

## 适用场景

- 触摸屏点击正常，但**长按、拖动都不起作用**：长按按钮只触发一次，拖动滑条要松手才跳到终点或根本不动。
- 板上内核没有编译 `hid-multitouch`（PYNQ-ZU 镜像 6.6.10-xilinx 即如此），多点触控屏被 `hid-generic` 接管。
- 不想（或不能）重编内核、装驱动，只需要在自己的程序里拿到按下 / 移动 / 抬起。

## 诊断

1. `cat /proc/bus/input/devices` 找到触摸屏对应的 `eventN`，确认驱动（`hid-generic` 而非 `hid-multitouch`）。
2. 让人按住屏幕 3 秒，同时读 `/dev/input/eventN` 的原始事件（`evtest`，或用本目录脚本的打印模式）：
   - 按住期间 **ABS_X / ABS_Y 持续上报**（实测约 90 次/秒）；
   - 但每次上报里空的手指槽位都会把 `BTN_TOUCH` / `BTN_TOOL_FINGER` 清零 → libinput / X 把每次触摸都当作"刚按下就松开"的点击。
   - 抬起时上报一次 X = Y = 0。
3. 如果按住期间根本没有持续上报，这个办法不适用（是硬件 / 连接问题，见下方"来源"中的 USB 供电问题）。

## 使用方法

`evdev_touch.py`（本目录）在一个线程里直接读 evdev，把"手指 0"的坐标流转成 `down(x, y)` / `move(x, y)` / `up()` 回调（屏幕像素）：

```python
from evdev_touch import EvdevTouch
t = EvdevTouch(EvdevTouch.find("USB2IIC_CTP"), (1024, 600), down=on_down, move=on_move, up=on_up)
threading.Thread(target=t.run, daemon=True).start()
```

- **点击仍走原来的路径**（X 发给 Qt 的 click），本模块只补长按和拖动，二者互不干扰。
- 在 Qt 里：回调中只发信号（`pyqtSignal`），在主线程用 `QApplication.widgetAt(x, y)` 或控件几何判断手指在哪个控件上。
- 长按：`down` 落在按钮上后启动定时器（如 0.4 s 后每 0.1 s 触发一次），`up` 或 `move` 移出按钮时停止。
- 拖动：`down` 落在滑条上开始拖动，`move` 更新滑块，`up` 时提交最终值。
- 坐标按 ABS 的逻辑最大值（本例 32767）线性换算到屏幕，假设触摸面板覆盖整块屏幕；有偏移时在这里校准。
- 进程需要读 `/dev/input/eventN` 的权限（root 或 input 组）。

## 已验证效果

RX 板 1024×600 触摸屏（沁恒 USB2IIC_CTP，10 点 HID 触控），PYNQ-ZU 镜像未改内核：GUI 的衰减 "−/+" 按钮长按连调、滑条拖动跟随手指均正常，
点击行为不变。实现见 `src/sw/rx/jscc_gui.py` 的 `TouchHold` 与 `touch_down/move/up`。

## 来源（从哪次失败中总结）

2026-10-06 给 GUI 的 "−/+" 按钮加长按功能，用 Qt 的 `autoRepeat` 实现后在触摸屏上不起作用。抓取 evdev 原始事件后发现问题不在 Qt：
内核没有 hid-multitouch，X 只收到瞬时点击。于是绕过 X，直接读 evdev。

此前（10-05）同一类屏还出现过触摸控制器在 USB 上反复掉线（`error -32 / -71`），原因是 USB 供电不足和线材问题，
给屏幕单独供电、换线后解决——排查时先确认设备稳定存在，再看驱动和协议。
