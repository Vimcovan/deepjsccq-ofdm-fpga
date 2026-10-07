# 仿真与验证

| 目录 | 验证对象 | 方法 | 结果 |
|---|---|---|---|
| `network/` | DeepJSCC-Q 编码器（256×256×3 → 32768 个复符号）与解码器（反向）RTL | xsim（XPM，断言打开），输入 DIV2K 验证图，AXI-Stream valid / ready 随机化（90 % / 80 %），与整数参考模型（`src/model/int_ref.py`、`golden_np.py`）的输出逐比特比对 | **编码器、解码器各 2 帧比特精确**（`results/encoder_xsim_20260930.log`：17 717 420 周期；`results/decoder_xsim_20260930.log`：14 803 719 周期） |
| `phy/` | OFDM TX 基带（长帧、包模式帧缓存不欠载）、OFDM RX（同步、双 LTF 信道估计、SFO / CPE 跟踪）、双板实采数据回放 | `tb_tx_*.sv` 生成 / 导出帧，`tb_rx_*.sv` 读入激励并导出星座、斜率、输出；`tb_cap_2board.sv` 回放两板实测 ADC 采样 | 激励与输出文件放在 `phy/sim_data/`（体积大，未入库；由 `tb_tx_*` 导出或用 `board/tests/adc_frames.py` 采集） |
| `sscc/` | SSCC 基线：`sscc_tx`（扰码、K=7 卷积码、交织、64QAM）→ AWGN → `sscc_rx`（Viterbi IP） | `vivado -mode batch -source run_sim.tcl -tclargs "FRAMES:1 SNR:13"`，`sscc_ref.py` 为 Python 参考 | `results.txt` / `results2.txt`：无噪声 0 字节错误、32768 个符号与参考 0 不一致；各 SNR / 软硬判决下的字节错误数 |

说明：

- `network/` 的运行脚本（`run_*.ps1`）沿用网络工作区的目录结构（RTL 在上级目录 `rtl/`、参数在 `runs/fpga_export_w8a12/`），
  在本仓库中对应 `src/hw/{tx,rx}/rtl/network/` 与 `data/model/`。
- 上板后的端到端验证（空口 PSNR–SNR、帧率、分段时延）见 `board/tests/` 与 `data/measurements/`。
