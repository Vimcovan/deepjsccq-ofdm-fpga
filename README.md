# deepjsccq-ofdm-fpga

基于 FPGA 的 DeepJSCC-Q 实时无线图像传输系统：两块 PYNQ-ZU（Zynq UltraScale+ xczu5eg）+ 两块 FMCOMMS3（AD9361），
DeepJSCC-Q 编解码器（W8A12 量化，逐层流式卷积引擎）与类 802.11a OFDM 物理层全部在 PL 中实现，经 915 MHz 空口
实时传输 256×256 彩色图像，30 fps。另含一个分离信源信道编码（SSCC：JPEG + K=7 卷积码 + 64QAM）基线，与 DeepJSCC-Q
共用同一物理层、同一发射功率，用于对比抗噪性能。

全国大学生嵌入式芯片与系统设计竞赛 · 2026 FPGA 赛道 · 自主选题。

## 主要结果（实测，空口，DIV2K 0802）

| 指标 | 结果 | 数据 |
|---|---|---|
| PSNR–SNR | DeepJSCC-Q：SNR ≥ 20 dB 时 31.7–32.0 dB，SNR 5.5 dB 时 26.5 dB，平缓退化；SSCC 在 SNR 约 17–20 dB 处悬崖式失效 | `data/measurements/psnr_snr/` |
| 帧率 | 30 fps：连续 600 s 收到 18000 帧 | `data/measurements/fps/` |
| 时延（PL + 空口） | 编码 38.20 ms / 传输 2.87 ms / 解码 30.39 ms，合计 71.47 ms（中位数） | `data/measurements/latency/` |
| 视觉对比 | 同一信道下原图 / DeepJSCC-Q / SSCC 解码图与 PSNR / SSIM | `data/measurements/psnr_snr/k0802_v3_visual*` |
| 资源 / 时序 | TX：LUT 52 666（45 %）、BRAM 104.5（73 %）、URAM 10、DSP 243，WNS +0.151 ns；RX：LUT 70 768（60 %）、BRAM 123.5（86 %）、URAM 25、DSP 394，WNS +0.234 ns（xczu5eg） | `build/reports/` |
| 功耗（Vivado 估算） | 片上合计 TX 4.49 W / RX 4.94 W，其中 PS 2.73 W | `build/reports/*_power.rpt` |

## 系统组成

```
TX 板：USB 摄像头 / 演示视频 / 预设图 → PS 裁剪 256×256 → DMA → PL：DeepJSCC-Q 编码器（250 MHz）→ PN 扰码
       → 64QAM 符号映射 → OFDM（64 点 IFFT，48 数据 + 4 导频子载波）→ 前导 → 帧缓存 → AD9361（20 MSPS，915 MHz）
RX 板：AD9361（快速 AGC，PS 初始化）→ PL：同步、双 LTF 信道估计、逐符号 SFO / CPE 跟踪 → 软符号
       → DeepJSCC-Q 解码器 → DMA → PS → 1024×600 触摸屏 GUI（另含 SSCC 译码：Viterbi IP + PS 端 JPEG）
帧结构：一帧 = 一幅图 = 32768 个 64QAM 符号 = 683 个 OFDM 符号，空中 2.748 ms，30 帧/s
```

## 目录

| 目录 | 内容 |
|---|---|
| `src/hw/tx`、`src/hw/rx` | 两块板的 PL 设计：`rtl/`（`network/` 编解码器、`phy/` OFDM 与 AD9361 接口、`ps/` 寄存器与 DMA 接口、`top/`）、`constr/`、`ip/*.xci`、`bd/`（PS 块设计脚本）、`files.txt`（部署版工程的源文件清单） |
| `src/network` | 网络 RTL 生成器：从量化参数生成各层顶层与权重初始化文件（`gen_rtl_top.py`、`gen_rtl_init.py`、`memory_plan.py`、`tools_create_vivado_projects.py`），`syn/` 卷积引擎 OOC 综合 |
| `src/model` | DeepJSCC-Q 模型、训练、训练后量化（W8A12）与整数参考模型、导出、OFDM 链路评估（见 `src/model/README.md`） |
| `src/sw` | 板上软件：`tx/`（取图、编码器驱动、衰减控制）、`rx/`（接收服务、AD9361 初始化与 AGC 看门狗、GUI）、`common/`（UDP 协议、SSCC 包格式）、`systemd/`、`tools/`、`board_setup/`（可选：GUI 的 PyQt5 与 Mali-400 lima 驱动） |
| `sim` | `network/` 编解码器 RTL 与整数参考模型比特精确比对；`phy/` OFDM 基带；`sscc/` SSCC 基线（见 `sim/README.md`） |
| `build` | 一键构建脚本 `build_hw.tcl`（从本仓库重建的结果与部署版资源、时序完全一致）；`reports/` 资源、时序、功耗报告 |
| `board` | `bitstreams/` 部署版比特流（含 SHA-256）；`tests/` 板上测量与诊断脚本 |
| `data` | `model/` 部署模型的检查点（`checkpoint/`）、量化后的权重与 RTL 初始化数据；`measurements/` 实测数据与图 |
| `report` | 设计报告与大模型协作记录 |
| `skill` | 技能包 |

## 硬件

- 2 × PYNQ-ZU（xczu5eg-sfvc784-2-e），PYNQ 镜像（Python venv `/etc/profile.d/pynq_venv.sh`）
- 2 × AD-FMCOMMS3-EBZ（AD9361），LVDS 1R1T，FDD，915 MHz，参考时钟 40 MHz
- TX：USB UVC 摄像头（可选）；RX：1024×600 触摸屏（DisplayPort）
- 网络：PC ↔ RX 板 `192.168.3.1`；RX ↔ TX 板间网线，TX `192.168.4.1`、RX 侧 `192.168.4.2`

## 快速上手（使用部署版比特流）

1. 把 `board/bitstreams/jscc_tx.{bit,hwh}` 和 `src/sw/tx/*`、`src/sw/common/*` 拷到 TX 板 `/home/xilinx/claude/tx/`；
   `board/bitstreams/jscc_rx.{bit,hwh}` 和 `src/sw/rx/*`、`src/sw/common/*` 拷到 RX 板 `/home/xilinx/claude/rx/`。
   （比特流、`.hwh` 与 Python 程序放在同一目录；其他路径需同步修改 `src/sw/systemd/*.service`。）
2. TX 板 `media/`：演示视频 `src/sw/tx/media/colorful_256.mp4`（默认 `--video`）；预设图由 `src/sw/tools/make_presets.py` 从 DIV2K 生成到 `media/presets/`。
3. 安装服务：`src/sw/systemd/*.service` 拷到 `/etc/systemd/system/`，`systemctl enable --now jscc-tx`（TX）、
   `jscc-rx jscc-gui`（RX）。上电约 1 分钟后触摸屏显示 GUI。
4. 板上程序以 root 运行；`rx_server.py` 启动时下载比特流并由 PS 初始化 AD9361（约 25 s）。

## 从源码重新构建比特流

```
vivado -mode batch -source build/build_hw.tcl -tclargs tx 8
vivado -mode batch -source build/build_hw.tcl -tclargs rx 8
```

在 `build/work/<tx|rx>` 新建工程、按 `src/hw/<side>/files.txt` 加入源文件与 IP、用 `bd/` 脚本生成 PS 块设计，
默认策略综合 / 实现，输出 `build/out/jscc_<side>.{bit,hwh}` 与资源 / 时序 / 功耗报告。工具：Vivado 2025.2。

## 从模型重新生成网络 RTL

`src/model/export_fpga.py` 导出量化参数（`data/model/params`、`rtl_init`、`manifest.json`）→ `src/network/gen_rtl_init.py`、
`gen_rtl_top.py` 生成各层 RTL 与初始化文件 → `tools_create_vivado_projects.py` 把权重文件路径展平为文件名
（`rtl_init__<layer>__<name>.mem`）→ 即 `src/hw/{tx,rx}/rtl/network/` 中的文件。

## 实测方法

见 `board/tests/` 各脚本开头的说明：`measure_link.py`（PSNR / SNR / EVM 扫描，先到最大衰减再逐点降低）、
`analyze_const.py`（固定图像下以参考星座计算数据辅助 SNR）、`pl_events.py` + `seg_latency.py`（两板 PS 轮询 PL
帧计数器，按数据流配对计算分段时延）、`plot_*.m`（MATLAB 出图）。

## 许可

MIT，见 `LICENSE`；第三方内容见 `THIRD_PARTY.md`。
