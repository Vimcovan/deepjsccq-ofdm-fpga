> 开发过程记录（2026-10-07 收录，路径已脱敏）。文中工程 / 工具目录指开发时的本地目录，与本仓库结构不同；原始抓取数据体积大，未入库。

# OFDM PHY 与 DeepJSCC-Q 对接说明

更新时间：2026-09-30
适用工程：`OFDM_TX_JSCC`、`OFDM_RX_JSCC`
DeepJSCC-Q 工程：`DeepJSCC-Q-FPGA 工作区`（交接文档 `docs\HANDOFF.md`，接口契约 `docs\PHY_INTERFACE.md`）

本文说明 OFDM 物理层这一侧已经做了什么、接口怎么定义，以及接入 DeepJSCC-Q 编码器和解码器的具体方案。原来的 `OFDM_TX` / `OFDM_RX` 工程（比特链路、卷积码 + Viterbi）保持不变，所有对接工作只在两个 `*_JSCC` 副本上做。

---

## 1. 系统概览

```
TX 板 (xczu5eg)                                                   RX 板 (xczu5eg)
┌────────────────────────────────────────────┐                   ┌──────────────────────────────────────────────┐
│ 图像源 ─► DeepJSCC 编码器 ─► CDC ─► OFDM TX │  915 MHz 空口     │ OFDM RX ─► URAM 帧缓存 ─► CDC ─► DeepJSCC 解码器 │
│  (待定)     250 MHz        FIFO   100 MHz   │ ───────────────►  │ 100 MHz    (丢帧式)      FIFO   250 MHz    ─► 图像宿 │
│                              URAM 整帧缓存 ─► DAC │  AD9361      │                                               (待定) │
└────────────────────────────────────────────┘                   └──────────────────────────────────────────────┘
```

- 两块 PYNQ-ZU（xczu5eg-sfvc784），各配一块 FMCOMMS3（AD9361），LVDS 1R1T、20 MSPS、915 MHz。发端 AD9361 只发、收端只收。
- PHY 时钟域 `clk_100M`，由现有 `clk_gen` 产生；DeepJSCC 网络目标时钟 250 MHz。
- 比特级编解码全部去掉，网络和 PHY 之间直接传 IQ 星座点。

---

## 2. 接口契约（冻结）

与 DeepJSCC `docs\PHY_INTERFACE.md` 一致：

| 项目 | 约定 |
|---|---|
| 数据 | AXI-Stream，`tdata[23:0] = {Q[11:0], I[11:0]}`，Q10 二补码（1.0 = 1024） |
| 调制 | 64-QAM，电平 158·(2k−7) = ±158 … ±1106，平均功率 1.0 |
| 帧长 | 每帧 32768 个符号（64×64×16/2），NHWC 顺序，通道 (2j, 2j+1) 配成 (I, Q) |
| 帧界 | 最后一个符号上 `tlast = tuser[0] = 1` |
| 反压 | 双向 valid/ready |

PHY 这一侧的补充约定：
- **TX 输入**：`tx_jscc_framer` 按计数分帧，`tlast` 只做检查（不在第 32767 个符号上会产生 `tlast_err` 脉冲），所以编码器必须严格输出每帧 32768 个符号。
- **RX 输出**：每帧严格 32768 个符号，`tlast`/`tuser` 在最后一个上。帧缓存放不下时丢的是整帧，不会输出半帧。
- **RX 输出幅度**：CPE 已经把导频归一化到 1024，所以输出就是 Q10，可以直接送给解码器的 `rx_in`。板上实测最终 EVM 约 −35 ~ −37 dB。

---

## 3. PHY 帧格式

| 字段 | 内容 |
|---|---|
| 采样率 | 20 MSPS，64 点 FFT，CP 16，子载波间隔 312.5 kHz |
| 前导 | STF 160 + LTF 160（GI 32 + LTF×2），共 320 个采样 |
| 数据 | 683 个 OFDM 符号 × 80 个采样；每个符号 48 个数据子载波 + 4 个导频 |
| 导频 | 子载波 ±7、±21，值 [1, 1, 1, −1] × 1024，每个符号都一样 |
| 子载波顺序 | fftshift 后下标 6…58，去掉 11/25/32/39/53；TX `pilot_insert` 和 RX 去导频的顺序一致 |
| 补零 | 32768 = 682×48 + 32，最后一个 OFDM 符号的后 16 个数据子载波填 0（TX 补，RX 丢） |
| 帧长 | 320 + 683×80 = 54960 个采样 = 2.748 ms |
| 帧间隔 | TX 顶层 `GAP_CYCLES` 目前为 50 µs；接入编码器后按帧就绪节奏发送（见 §6.4） |

### 3.1 PN 符号翻转（降 PAPR）
DeepJSCC 输出的符号沿 NHWC 顺序是相关的：相邻符号相关系数 0.17~0.27，相隔 16 个符号达到 0.28~0.42。这会让 OFDM 的 PAPR 比随机 64-QAM 高 1~2 dB（99% 分位 10.1~10.7 dB，整帧最大 11.7~12.4 dB）。

- **做法**：TX 在插导频之前、RX 在均衡之后，都用 `iq_pn_scrambler` 对 I、Q 分别翻转符号。
- **LFSR**：802.11 扰码多项式 x^7+x^4+1，种子 `7'b1011101`；每个符号走两步，第 1 位控制 I，第 2 位控制 Q（1 表示取反）；每帧复位。
- **效果**：PAPR 回到随机 QAM 的水平（99% 分位约 9.4~9.8 dB）。约 20 个 LUT，不用乘法器，对网络完全透明。
- **数字余量**：3 张测试图的 TX 时域峰值 |I|、|Q| 最大 1765（满量程 2047），没有削顶。

### 3.2 RX 同步与均衡（已在板上验证）
- **帧检测**：STF 自相关，并从 STF 估计 CFO，用 DDS 纠正。
- **定时同步**：LTF 互相关，门限 0.375。相关器系数使用 `coe\ltf_cplx_bo8.coe`，即 LTF 匹配滤波器循环移位 9 位，使所有 FFT 窗口提前 8 个采样落进 CP，给 SFO 漂移留余量。板上实测窗口位置 +8.0 ~ +8.1 个采样。
- **信道估计**：LTF1 与 LTF2 平均，逐子载波估计，不做平滑。
- **跟踪式 SFO**：旋转放在 CPE 之前，残差用导频 LS 估计，二阶环（R += e/256，A = A_pred + e/8），每帧清零。RTL 仿真验证 ±40 ppm、683 个符号下 0 误码。
- **CPE**：用 4 个导频的和做公共相位和幅度归一化。

---

## 4. 缓存与跨时钟域（设计依据）

原则：整条链路都支持反压，只在"实时接口"和"慢速网络"之间放一个帧缓存。

| 位置 | 模块 | 模式 | 容量 | 依据 |
|---|---|---|---|---|
| TX，DAC 前 | `uram_frame_fifo`，在 `tx_baseband_jscc` 里 | `PACKET_MODE=1`：只放出完整帧，输入满了就反压 | 6 URAM = 24576 字 × 72 位 = 73728 个采样（1.34 帧） | 编码器约 1 M 符号/秒，DAC 要以 20 MSPS 连续取 2.75 ms，必须先攒满一帧时域采样再发 |
| RX，均衡之后 | `uram_frame_fifo`，在 RX 顶层 | `PACKET_MODE=0`：输入不反压；帧开头判断放不放得下，放不下就整帧丢弃并计数 | 6 URAM（2.25 帧） | ADC 连续不停，解码器每帧要约 33 ms；如果把缓存放在 ADC 侧，要存 33 ms × 20 MSPS ≈ 66 万个采样，不可行。放在均衡之后只需存有效载荷 |
| 网络 ↔ PHY | `axis_async_fifo` | Gray 码指针、2 级同步、LUTRAM，深度 32 | — | 只做跨时钟域，不当缓存用 |

- 每个 72 位字打包 3 个 24 位样本。帧长不是 3 的倍数时，每帧最后一个字只装部分样本，读写两侧都按帧计数对齐（单元仿真覆盖了这种情况）。
- URAM 只有一个时钟，所以两个帧缓存都放在 `clk_100M` 域，跨时钟域 FIFO 放在帧缓存和网络之间。
- 综合时 URAM 读出没有吸收进流水寄存器，会报 WARNING，在 100 MHz 下没有问题。如果以后把帧缓存挪到 250 MHz 域，要加一级读流水。

---

## 5. 当前实现状态

### 5.1 新增和修改的 RTL
源文件的主副本在 `jscc_rtl\`，已拷进两个工程的 `sources_1\new\jscc\`：

| 文件 | 作用 |
|---|---|
| `iq_pn_scrambler.sv` | PN 符号翻转（§3.1），TX 和 RX 共用 |
| `tx_jscc_framer.sv` | 32768 个符号加 PN，再补 16 个零，变成 683×48 个数据子载波 |
| `rx_jscc_framer.sv` | 32784 个均衡输出去掉补零、去掉 PN，打 tlast/tuser |
| `uram_frame_fifo.sv` | URAM 帧缓存（§4） |
| `axis_async_fifo.sv` | 跨时钟域 FIFO（§4） |
| `iq_prbs_source.sv` | 编码器替身：PRBS-15 格雷映射 64-QAM，每帧复位 |
| `rx_iq_checker.sv` | 解码器替身：硬判决后和 PRBS 比较，统计未编码比特误码；`throttle` 可模拟慢解码器 |
| `tb\tb_jscc_path.sv` | 不含 OFDM 的快速单元测试（组帧、PN、丢帧、打包 FIFO） |

工程内的改动：
- **TX_JSCC**：新增 `ofdm_tx\tx_baseband_jscc.sv`，去掉了扰码、卷积、交织、QAM；顶层改成 `iq_prbs_source → axis_async_fifo → tx_baseband_jscc → 20 MSPS 节拍闸门 → DAC`。
- **RX_JSCC**：
  - `rx_baseband_top` 去掉 Viterbi 链路，输出 24 位 IQ 并带 tlast/tuser。
  - 顶层改成 `rx_baseband_top → uram_frame_fifo(丢帧) → axis_async_fifo → rx_iq_checker`。
  - 去掉了 ILA。
  - telemetry 改成单缓冲：主机读取时 enable=0，会中止正在进行的采集。
  - telemetry 超时改为 100 ms，因为 30 fps 下帧间隔约 33 ms。
- **两个工程共同**：AD9361 配置表 `ad9361_config_lut` 的函数输入改成 11 位（2048×19 的 ROM，原来是 8192×19）。

### 5.2 验证情况
- **单元测试**（`jscc_rtl\tb\run.bat`）：0 误码；限流时整帧丢弃、恢复后正常；打包 FIFO 帧内零断流。
- **TX 仿真**（`tb_tx_jscc`，683 个符号 × 2 帧）：零断流。解调 TX 输出并去掉 PN 后，和独立的 Python PRBS/PN 模型逐符号一致，误差 −61.7 dB，只有舍入误差。
- **RX 仿真**（`tb_rx_jscc`）：激励由 RTL TX 输出加 ±40 ppm SFO、20 kHz CFO、多径、SNR 30 dB 生成，脚本 `tools\make_jscc_stim.py`。
  - 分帧和帧长全对，丢帧 0。
  - EVM −27.7 / −27.3 dB。
  - 39 万个未编码比特中有 1 个误码，位于多径造成的衰落子载波，是噪声尾部事件。
  - 这个仿真 2 帧要跑约 55 分钟。
- **上板（2026-09-30）**：
  - 约 364 帧/秒，7.15 亿个未编码比特 0 误码，丢帧 0。
  - GUI 另一段累计统计：2.35×10^10 个比特中 4 个误码，BER 1.7×10^−10。
  - 最终 EVM：帧头 −36.6 dB，帧尾 −34.9 dB；离判决边界最近的点还剩 69/158。

### 5.3 实测资源（布局布线后，时序都收敛）

| 工程 | LUT | FF | BRAM36 | URAM | DSP | WNS |
|---|---|---|---|---|---|---|
| OFDM_TX_JSCC | 2,936 | — | 3 | 6 | 8* | +6.28 ns |
| OFDM_RX_JSCC | 11,019 | — | 12 | 6 | 82 | +4.20 ns |

\* 其中 2 个 DSP 是 `iq_prbs_source` 的电平乘法，换成编码器以后就没有了。

---

## 6. 对接方案

### 6.1 时钟和复位
- 在 `clk_gen`（MMCM）上加一路 250 MHz 输出，两块板都要。输入是板载差分 sysclk；可以直接改 IP 配置，也可以单独加一个 MMCM。
- 250 MHz 域要有自己的同步复位：拿 `rst_n` 和 MMCM 的 `locked` 在 250 MHz 下做 2 级同步释放。PHY 域的复位保持原样（RX 仍然受 VIO 软复位 `vio_rx_rst` 控制）。
- 跨时钟域 FIFO 两侧各用自己时钟域的复位：`s_rst_n` 和 `m_rst_n`。

### 6.2 TX 顶层（`OFDM_TX_JSCC\...\top_module.v`）
```
图像源 ─(12 位像素元素, NHWC)─► blk_enc_0_latent_idx (250 MHz)
      ─(24 位 IQ + tlast/tuser)─► axis_async_fifo (s_clk=clk_250M, m_clk=clk_100M)
      ─► tx_baseband_jscc (clk_100M) ─► 现有 20 MSPS 节拍闸门 ─► ad9361_top
```
- 把 `u_iq_src`（`iq_prbs_source`）换成编码器，`u_iq_cdc` 的 `s_clk`/`s_rst_n` 改成 250 MHz 域。
- 编码器输入：`s_in_tdata[11:0]`，按 DeepJSCC 的约定送 256×256×3 的 uint8，逐元素 NHWC，带 tlast/tuser。具体约定以 DeepJSCC 工程文档为准。
- **建议保留 PHY 自测模式**：用一个 VIO 输出或参数，在 `iq_prbs_source` 和编码器之间二选一，RX 侧同理。这样出问题时可以先确认 PHY 本身没问题。

### 6.3 RX 顶层（`OFDM_RX_JSCC\...\top_module.v`）
```
ad9361_top ─► rx_baseband_top (clk_100M) ─► uram_frame_fifo (丢帧) ─► axis_async_fifo (clk_100M → clk_250M)
           ─► blk_rx_in_output (250 MHz) ─(8 位 RGB, tlast/tuser)─► 图像宿
```
- 把 `u_iq_check`（`rx_iq_checker`）换成解码器，`u_dec_cdc` 的 `m_clk`/`m_rst_n` 改成 250 MHz 域。
- 跨时钟域 FIFO 的 `tdata` 是 `{tuser, tlast, IQ}`，共 26 位，拆开后接解码器的 `s_in_tuser`/`s_in_tlast`/`s_in_tdata`。
- VIO 的 `probe_in4 = {fb_dropped, fb_frames_in}` 可以继续用来监视丢帧。比特误码统计在接入解码器后就没有了，建议改成监视图像质量，见 §7。

### 6.4 帧节奏
- 编码器约 30 fps（每帧 8.33M 个周期 @250 MHz），PHY 发送一帧只要 2.75 ms，空口占空比约 8%。
- TX 顶层的节拍闸门在 SEND 状态会等 `bb_tvalid`；帧缓存只放出完整帧，所以编码器每完成一帧，PHY 就发一帧，帧间隔自然由编码器决定。`GAP_CYCLES`（50 µs）是两帧之间的最小间隔，可以保持不变。
- RX 帧缓存能存 2.25 帧。只要解码器平均处理速度不低于帧率，就不会丢帧；丢帧会记到 `fb_dropped`。

### 6.5 时序约束（跨时钟域）
两个时钟之间只通过 `axis_async_fifo` 交互，建议加以下约束：
```tcl
# Gray 码指针和 RAM 读路径：按快时钟一个周期约束数据路径, 不做时钟相位分析
set_max_delay -datapath_only 4.0 -from [get_cells -hier -filter {NAME =~ *u_*_cdc/wgray_reg*}] -to [get_cells -hier -filter {NAME =~ *u_*_cdc/wgray_sync1_reg*}]
set_max_delay -datapath_only 4.0 -from [get_cells -hier -filter {NAME =~ *u_*_cdc/rgray_reg*}] -to [get_cells -hier -filter {NAME =~ *u_*_cdc/rgray_sync1_reg*}]
set_max_delay -datapath_only 4.0 -from [get_cells -hier -filter {NAME =~ *u_*_cdc/mem_reg*}]
```
实现后用 `report_cdc` 确认没有未约束的跨时钟路径。不建议直接对整个时钟组做 `set_clock_groups -asynchronous`：那样会把 Gray 码指针路径完全放开，失去对延迟的约束。

### 6.6 资源预算

| | LUT | BRAM36 | URAM | DSP |
|---|---|---|---|---|
| TX 板：编码器（OOC 综合）+ TX_JSCC | 46,054 + 2,936 ≈ 49,000（42%） | 100 + 3 = **103（72%）** | 4 + 6 = 10 | 233 + 6 = 239 |
| RX 板：解码器（OOC 综合）+ RX_JSCC | 50,178 + 11,019 ≈ 61,200（52%） | 100 + 12 = **112（78%）** | 18 + 6 = 24 | 312 + 82 = 394 |

- 还没算图像源和图像宿的存储：一帧 256×256×3 字节约 1.57 Mb，每个 72 位字打包 9 字节时约 6 块 URAM，每块板都放得下（TX 16/64，RX 30/64）。
- 编码器和解码器的数字来自 OOC 综合，实际布局布线后会有 ±5% 左右的出入。

### 6.7 时序收敛风险
- 250 MHz 网络加上 75~80% 的 BRAM 占用，是这次对接的主要风险。编码器和解码器 OOC 综合的 WNS 只有 +0.71 / +0.52 ns。
- 建议的顺序：
  1. 先用 PRBS 替身加上 250 MHz 空载的跨时钟域 FIFO 跑一次完整实现，确认时钟、复位和约束都没问题。
  2. 再接入网络。
- 如果时序不收敛，可以：
  - 给网络划 Pblock，PHY 固定在 FMC/LVDS 附近的时钟区域。
  - 让 DeepJSCC 的生成器把大的 FIFO 放进 URAM（例如 `dec.8.out.b` 13816 深、`dec.7.out.b` 9717 深），缓解 BRAM 布线拥塞。
  - 把网络的时钟目标降到 200 MHz 再评估帧率。

---

## 7. 验证计划

1. **仿真：TX 用黄金向量**。把 `iq_prbs_source` 换成读 `golden\<img>\tx_iq24.mem` 的源，跑 `tb_tx_jscc`，用 Python 解调并去掉 PN 后和 `tx_iq24.mem` 比对，参考 `tb_tx_jscc` 已有的比对方法。
2. **仿真：RX 输出**。用第 1 步的波形经 `make_jscc_stim.py` 加信道，跑 `tb_rx_jscc`，把 RX 输出和 `tx_iq24.mem` 比较（EVM），再把输出送进解码器的 xsim/Questa 仿真，和黄金图像比 PSNR。长仿真很慢，建议只跑 1 帧，或者先把 NSYM 缩小做功能验证。
3. **端到端仿真**：编码器 → PHY TX → 信道 → PHY RX → 解码器，按 DeepJSCC 工程现有的脚本组织（`sim\run_top_questa.ps1`）。
4. **上板**：先用 PHY 自测模式（PRBS）确认 0 误码、0 丢帧；再切到网络，比较收端重建图像和 PC 上的浮点或定点参考输出。

---

## 8. 工具和调试

| 工具 | 用途 |
|---|---|
| `tools\start_telemetry_jscc.bat` | 一键启动：在后台启动 Vivado，连接或烧写 RX_JSCC，启动 GUI（`--program` 表示强制烧写） |
| `tools\telemetry_gui.py --jscc` | 按 64-QAM 网格显示星座和 EVM；抓到最后一个 OFDM 符号时排除补零；显示未编码误码和帧缓存丢帧；"start symbol"/"head/tail" 可以看帧尾 |
| `tools\vivado_hw\rxstat_jscc.tcl` | `::rxj::read`、`::rxj::measure <毫秒>`：读未编码误码和帧缓存计数 |
| `tools\vivado_hw\telemetry.tcl` | `::tm::attach <0/1> <impl 目录>`；JSCC 版本要传 `OFDM_RX_JSCC/OFDM_RX_JSCC.runs/impl_1` |
| `tools\make_jscc_stim.py <ppm>` | 由 TX 仿真输出生成 RX 激励 |
| `tools\vivado_hw\run_sim.bat <xsim 目录> <tb>` | 运行 `launch_simulation -scripts_only` 生成的仿真脚本 |

---

## 9. 已知坑

1. **改了 IP 配置以后**（例如系数文件），`generate_target` 加 `reset_run synth_1` 不会重跑 IP 的 OOC 综合，比特流里还是旧网表，但行为仿真用的是新模型。之前因此出过"仿真通过、板上 FER 70%"的问题。改 IP 以后一定要 `reset_run <ip>_synth_1`，并检查 dcp 的时间。
2. **Vivado batch 会话不会重新解析外部修改过的源文件**。改完文件要 `remove_files` + `add_files`，再 `update_compile_order`，否则新加的实例可能被标成 `IS_AUTO_DISABLED`。
3. **ROM 地址位宽**：函数或 case 的输入是 13 位，Vivado 就按 8192 深推 ROM；只在调用处截断地址没有用，要把函数输入本身改窄。
4. **`$readmem` 路径**：RTL 里写的是绝对路径，已经全部指向 `*_JSCC` 工程自己的目录；以后拷贝工程要一起改。
5. **URAM 没有初始化内容**，不能当 ROM 用。图像或权重类的只读数据只能放 BRAM，或者上电后再写进去。
6. **分帧完全靠计数**，包括帧检测、定时同步、信道估计、SFO、组帧和帧缓存，中间任何一级丢样本都会导致后面整帧错位。解码器必须每帧收到正好 32768 个符号；帧缓存保证输出要么是完整帧，要么整帧不出。
7. **telemetry 的 nerr** 按帧序号匹配；帧缓存丢帧以后，"this frame" 的误码可能对应到错误的帧，累计统计不受影响。
8. **AGC** 是稳态设置，天线移动后需要重新上电，这是 RF 模块的约定，不和基带耦合。

---

## 10. 待决策问题

1. **图像源和图像宿走什么通路？**
   - JTAG-to-AXI：约 170 KB/s，一幅图约 1.2 s，只够演示，比如 TX 循环发同一幅图，RX 由 PC 慢速读回。
   - PS 端 DDR 加以太网/USB。
   - PL 端的 HDMI。
   - 30 fps 实时视频需要后两种之一。
2. **编码器和解码器的连续多帧运行**：HANDOFF 里的整链多帧回归还没完成，需要确认帧间连续、反压下的吞吐是否满足 30 fps。
3. **250 MHz 能否在整板收敛**（§6.7）；不行的话要确定降频目标。
4. **收端丢帧或误同步时，解码器怎么恢复**：目前 PHY 保证每帧恰好 32768 个符号并带 tuser，解码器是否依赖 tuser 重新同步需要确认。
