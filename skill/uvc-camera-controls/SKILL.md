---
name: uvc-camera-controls
description: Use on an embedded Linux board (PYNQ image or similar) without v4l-utils when a USB UVC camera's image is too gray / dark / washed out and its controls (saturation, contrast, gamma, exposure, gain, white balance) must be listed, tuned live and fixed at start-up. Pure Python V4L2 ioctls, no package install; works while another process is streaming.
---

# 无 v4l-utils 时用 ioctl 读写 UVC 摄像头参数

## 适用场景

- 板上镜像没有 `v4l2-ctl`，又不方便（或不允许）安装软件包。
- OpenCV 的 `cap.set(CAP_PROP_...)` 对很多 UVC 控制项不起作用或映射不明确，而且只能在打开摄像头的那个进程里调用；
  想在采集程序**运行时**从另一个终端在线调参、看效果。
- 摄像头画面发灰、偏色、过暗，需要找出合适的饱和度 / 对比度 / gamma，并在程序启动时自动设定。

## 使用方法

`v4l2ctl.py`（本目录）只用 `ctypes` + `fcntl`，实现了 `VIDIOC_QUERYCTRL` / `G_CTRL` / `S_CTRL` 三个 ioctl：

```bash
python3 v4l2ctl.py list                                    # 默认 /dev/video0：所有控制项、当前值、范围、默认值
python3 v4l2ctl.py /dev/video0 set saturation=105 contrast=44 gamma=130
```

控制项名按 `QUERYCTRL` 返回的名字转成小写下划线（如 `exposure_time_absolute`、`white_balance_temperature`）。
V4L2 控制可以在别的进程正在采集时修改，画面立即生效。

**调参流程**

1. `list` 记下原值（便于回退）。
2. 逐项在线修改，同时从采集程序取一帧，算**客观指标**而不只凭肉眼：平均饱和度（HSV 的 S 通道均值）、平均亮度。
   每次只改一两项，记一张"设置 → 指标"表。
3. 注意曝光 / 增益的约束：室内光线下增益常已到最大，降增益会让画面变暗很多，这时应该调饱和度 / 对比度 / gamma，而不是动增益。
4. 选定后在采集程序启动时用同样的 ioctl 写入（本项目 `src/sw/tx/tx_camera.py` 的 `--saturation/--contrast/--gamma` 参数）：

```python
import os, fcntl, v4l2ctl
fd = os.open("/dev/video0", os.O_RDWR)
ctl = v4l2ctl.controls(fd)
for k, v in dict(saturation=105, contrast=44, gamma=130).items():
    fcntl.ioctl(fd, v4l2ctl.VIDIOC_S_CTRL, v4l2ctl.Control(ctl[k]["id"], v))
```

## 已验证效果

TX 板（PYNQ-ZU，PYNQ 3.1，USB UVC 摄像头，MJPG）：原设置（饱和度 55、对比度 36、gamma 140）画面平均饱和度只有 35/255；
改为饱和度 105、对比度 44、gamma 130 后为 80/255，平均亮度基本不变（112 → 108），曝光、增益不变。该组参数已固化为 `tx_camera.py` 默认值，
开机自动生效，日志打印设定后的回读值。

## 来源（从哪次失败中总结）

2026-10-06，演示中 TX 摄像头的画面"很灰，几乎分辨不出颜色"。板上没有 v4l-utils，而采集程序 `tx_camera.py` 正在运行，
希望不重启它就能在线调参。于是直接用 V4L2 ioctl 写了这个最小替代工具，边采集边调，按"平均饱和度 / 亮度"两个指标对比三组设置后固化。
