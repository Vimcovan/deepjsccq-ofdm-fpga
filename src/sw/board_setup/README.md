# RX 板可选环境（只影响 GUI）

链路本身（`tx_camera.py`、`rx_server.py`）只需要 PYNQ 镜像自带的 Python 环境。下面两项只为 RX 板触摸屏 GUI 服务：

| 项 | 作用 | 不装的后果 |
|---|---|---|
| `pyqt5/` | GUI 依赖：PyQt5 5.15、pyqtgraph、PyOpenGL | GUI 无法启动（链路照常工作，可在 PC 上运行 `jscc_gui.py`） |
| `gpu_lima/` | Mali-400 GPU 的 lima 内核驱动 | PHY 页 \|H\| 三维图改为二维瀑布图，其余功能不受影响 |
| `wifi/` | 两块板开机自动连接 WiFi（手机网页控制、远程登录） | 只能经 USB 网线访问板子 |

## PyQt5（`pyqt5/`）

`urls.txt` 列出 35 个 Ubuntu 22.04（jammy）arm64 软件包（Qt 5.15.3、PyQt5 5.15.6、pyqtgraph 0.12.4、PyOpenGL 3.1.5 及依赖）。
在能上网的电脑上下载后拷到板上，以 root 运行 `bash install.sh <包所在目录>`。板子能直接访问 Ubuntu 软件源时，
也可以直接 `apt install python3-pyqt5 python3-pyqt5.qtopengl python3-pyqtgraph python3-opengl`。

## lima 驱动（`gpu_lima/`）

PYNQ-ZU 镜像的内核（6.6.10-xilinx-v2024.1）没有打开 `CONFIG_DRM_LIMA`，这里在板上以外部模块方式编译 lima 及其依赖
（`gpu-sched`、`drm_shmem_helper`）。`src/` 取自 Xilinx/linux-xlnx 标签 `xlnx_rebase_v6.6_LTS_2024.1` 的
`drivers/gpu/drm/{lima,scheduler}` 与 `drm_gem_shmem_helper.c`（许可 GPL-2.0 / GPL-2.0 OR MIT，见各文件 SPDX 头，
不属于本仓库的 MIT 部分）。

板上内核是 gcc 12 编译的，而板上只有 gcc 11，因此：

1. 复制一份内核构建树（`/lib/modules/$(uname -r)/build`）到私有目录（脚本中为 `/home/xilinx/claude/kbuild`），
   用 `gen_arch_headers.sh` 生成 arm64 头文件、`build_modpost.sh` 编译 `modpost`——都不经过顶层 Makefile，避免用
   gcc 11 重跑 kconfig 改写配置；若已被改写，用 `restore_kconfig.py <构建树>` 恢复。
2. 在 `src/` 下 `make KDIR=<私有构建树> CC=<gcc-wrap 路径>`（`gcc-wrap` 去掉 gcc 11 不认识的 `-ftrivial-auto-var-init=zero`）。
3. 把 `gpu-sched.ko`、`drm_shmem_helper.ko`、`lima.ko` 拷到 `/lib/modules/$(uname -r)/extra/`，`depmod -a`，
   新建 `/etc/modules-load.d/lima.conf`（内容 `lima`），重启后出现 lima 的 `/dev/dri/renderD*`。
4. 检查：`python3 glprobe.py` 打印 OpenGL 渲染器；GUI 日志 `gui.log` 出现 `h3d_render: Mali400`。

GUI 的三维图由 `src/sw/rx/h3d_render.py` 在 lima 的 render 节点上用 GBM + EGL 离屏渲染（不经过 X），显示仍由
PYNQ 默认的 X 服务完成。

## WiFi（`wifi/`）

PYNQ-ZU 板载 Microchip WILC WiFi 模块（SDIO，驱动 `wilc_sdio`，网口 `wlan0`，只支持 2.4 GHz）。两块板都以 root 运行：

```
bash install.sh "<热点名>" "<密码>"
```

脚本用 `wpa_passphrase` 生成 `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`（只保存哈希后的密钥），启用 systemd 的
`wpa_supplicant@wlan0`（掉线 5 s 后重启）和 `wlan0-dhcp.service`（常驻 `dhclient`，拿不到地址就一直重试；启动前关闭 WILC 的
省电模式，否则往返时延约 170 ms，手机页面的视频流会卡顿）、`wlan0-event.service`（`wpa_cli` 事件脚本，每次连上热点都重启
`wlan0-dhcp`：在两个同名热点之间切换时 `dhclient` 会沿用旧租约，板子在新热点上没有地址），并去掉
`/etc/network/interfaces.d/wlan0` 中的 `auto` / `allow-hotplug`：PYNQ 的 ifupdown 钩子与设备热插拔同时启用 `wlan0` 时会
互相关掉对方。线下演示可用手机开 2.4 GHz 热点（与安装时同名同密码），两块板开机后自动连上，手机浏览器打开
`http://<RX 板地址>:8080` 即为控制页（`src/sw/rx/web_server.py`）；地址由热点分配，RX 触摸屏的“手机”页显示当前地址和二维码，
手机扫码即可打开。两块板各自
把画面发给手机，不经板间网线转发；WILC 的上行约 2.5 Mbit/s，每路画面限为 15 fps、JPEG 质量 65（约 0.9 Mbit/s），
WiFi 来不及发送时跳帧而不排队，画面始终是最新的。

