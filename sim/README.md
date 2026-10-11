# 仿真与验证

| 目录 | 验证对象 | 方法 | 结果 |
|---|---|---|---|
| `network/` | DeepJSCC-Q 编码器（256×256×3 → 32768 个复符号）与解码器（反向）RTL | xsim（XPM，断言打开），输入 DIV2K 验证图，AXI-Stream 输入 valid、输出 ready 随机拉低（占空比 90 % / 80 %），与整数参考模型（`src/model/int_ref.py`，及其 NumPy 独立实现 `golden_np.py`）导出的各层结果逐比特比对 | 编码器、解码器各连续 2 帧比特精确（`results/encoder_xsim_20260930.log`：17 717 420 周期；`results/decoder_xsim_20260930.log`：14 803 719 周期） |
| `phy/` | OFDM TX 基带（长帧、帧缓存不欠载）、OFDM RX（同步、双 LTF 信道估计、SFO / CPE 跟踪）、两板实采数据回放 | TX 测试平台生成并导出帧，RX 测试平台读入激励并导出星座、相位斜率和输出 | 激励与输出文件体积大，未入库；由 TX 测试平台导出或用 `board/tests/adc_frames.py` 采集 |
| `sscc/` | SSCC 基线：发射（扰码、K=7 卷积码、交织、64QAM）→ AWGN → 接收（Viterbi IP） | xsim，`sscc_ref.py` 为 Python 参考 | 无噪声时 0 字节错误，32768 个符号与参考完全一致；各 SNR 与软 / 硬判决下的字节错误数 |

## `network/`：神经网络

| 文件 | 作用 |
|---|---|
| `tb_top.sv` + `run_top_sim.ps1` | 由生成器产生的块级 / 整网顶层，与参考数据逐元素比对，多帧背靠背；`-Measure` 时记录各汇合 FIFO 的峰值占用，用于确定 FIFO 深度（`fifo_sizes.py` 合并结果） |
| `run_top_questa.ps1` | 同上，用 QuestaSim 运行（ROM 改为推断存储器，不需要 XPM 仿真库） |
| `run_decoder_background.ps1`、`run_full_chain_background.ps1` | 整个编码器 / 解码器的长时间后台仿真，产生 `results/` 中的日志 |
| `tb_conv_layer.sv` + `run_conv_sim.ps1` | 单个卷积层（行缓存 + 卷积引擎）与参考数据比对 |
| `tb_gdn.sv` + `run_gdn_sim.ps1` | 单个 GDN / IGDN 层与参考数据比对 |
| `tb_axis_line_buffer.sv` + `run_sim.ps1` | 行缓存：随机帧、两侧随机反压，与本地计算的窗口序列比对（含零填充与帧标志） |
| `tb_mul_serial.sv` | 串行乘法器：设计中用到的各种位宽，随机与边界值 |
| `tb_axis_async_fifo*.sv` | 网络与物理层之间的异步 FIFO：多种配置与最小深度压力测试、复位行为 |
| `tb_phy_interface.sv` | 网络与物理层之间的两个转换模块：`qam_tx`（编码器输出的 12 位潜变量判决为 64QAM 符号）、`rx_frame`（接收符号还原为解码器输入的潜变量） |
| `glbl_stub.sv` | 单独仿真 XPM 原语时需要的全局信号模块 |

运行脚本按开发时的目录编写：网络 RTL 位于脚本上一级的 `rtl/`，导出的模型参数位于 `runs/fpga_export_w8a12/`
（即 `src/model/export_fpga.py` 的输出目录）。在本仓库中运行前，把这两个路径分别改为 `src/hw/{tx,rx}/rtl/network/`
和 `data/model/`。

## `phy/`：OFDM 物理层

| 文件 | 作用 |
|---|---|
| `tb_tx_long.sv`、`tb_tx_jscc.sv` | OFDM 发射基带（后者为 DeepJSCC-Q 帧格式，PRBS 64QAM 源），按 20 MSPS 读出，检查帧开始后不欠载，导出采样供 RX 仿真 |
| `tb_rx_long.sv`、`tb_rx_jscc.sv` | OFDM 接收基带：两帧分别加正、负 SFO，再加 CFO、多径、AWGN，检查同步、信道估计与 SFO / CPE 跟踪 |
| `tb_cap_2board.sv` | 把两板空口实测的 ADC 采样回放进接收基带 |

## `sscc/`：SSCC 基线

```
vivado -mode batch -source run_sim.tcl -tclargs "FRAMES:1 SNR:13"
```

参数：`FRAMES` 帧数，`SNR` 信噪比（dB，省略为无噪声），`HARD:1` 改为硬判决 Viterbi 输入，`DUMP:1` 导出发射符号供 `sscc_ref.py` 比对。

- `results.txt`：软判决下 SNR 16 / 13 / 11 dB 的字节错误数（0 / 7 / 559，每帧 12 272 字节）；
- `results2.txt`：无噪声时与 Python 参考的逐符号比对（0 不一致），以及 SNR 13 dB 硬判决的字节错误数（2100）。

上板后的端到端验证（空口 PSNR–SNR、帧率、分段时延）见 `board/tests/` 与 `data/measurements/`。
