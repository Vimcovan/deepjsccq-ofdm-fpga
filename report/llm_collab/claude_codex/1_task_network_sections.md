你是 DeepJSCC-Q FPGA 网络部分（模型、量化、RTL 生成器、卷积引擎）的原作者，工作区是 <codex-work>\DeepJSCC-Q-FPGA。
现在整个系统（两块 PYNQ-ZU + AD9361，OFDM 空口实时传输）已经完成并上板实测，代码整理到了开源仓库
<work>\deepjsccq-ofdm-fpga（当前工作目录）。我是 Claude Code，负责系统、PHY、实测部分；请你起草设计报告中
网络相关的两节。报告提纲见 report/drafts/outline.md。

## 任务

写一个文件：report/drafts/codex_network.md，包含两节：

### 2.2 DeepJSCC-Q 模型与网络硬件
- 模型：结构（编码器 / 解码器模块序列，GDN/IGDN、注意力、PixelShuffle），C=32、Clat=16、下采样 4×，32768 个 64QAM 符号/帧，
  spp=0.5；训练（train_v2.py：AWGN 10 dB、KL 熵正则 0.05、软/硬量化直通、epoch 1186）；W8A12 训练后量化与整数参考模型；
  软件精度（浮点 vs W8A12：DIV2K 31.27 / 31.22、Kodak 32.65 / 32.59）。
- 硬件：逐层流式数据流、输出通道并行 P 的选取规则（式 8）、累加位宽、重定标、GDN/IGDN 的整数实现（平方根、除法）、
  sigmoid 分段线性、分支输入复用（RU / RB / ATT）、权重 ROM 三种映射、激活缓存 BRAM/URAM 分配、与 PHY 的接口
  （24 位 {Q,I} Q10，valid/ready，tlast/tuser）。
- RTL 验证：编码器 / 解码器各 2 帧与整数参考模型比特精确（仓库 sim/network/results/*.log）。

### 4.1 网络侧 PPA 优化前后对比
- 给出"优化前 → 优化后"的真实数据，例如：论文原配置（Clat 大、16× 下采样）vs 本文配置的权重 / MAC / 存储；
  并行度统一 vs 按层配置；分支复用前后；激活缓存迁入 URAM 前后的 BRAM；以及与 GLOBECOM 2025（Isobe 等）FPGA DeepJSCC
  的资源 / 工作量对照（注意口径边界）。
- **只用你工作区里真实存在的数据**（综合报告、memory_plan、evidence.json、日志、manifest）。某项没有"优化前"的实测数据，
  就明确写"未单独测量"，或者给出由公式计算的值并标明是计算值。不要编数字。

## 参考材料
- 你之前的论文 v3：<codex-work>\DeepJSCC-Q-FPGA\docs\DeepJSCC_Q_FPGA_paper_draft_v3.md、数据来源
  docs\DeepJSCC_Q_FPGA_data_sources.md、docs\figures\revised\evidence.json、docs\MODEL_STRUCTURE.md、docs\memory_plan.md、
  syn\、vivado_projects\ 下的 OOC 报告。
- 仓库中对应的副本：src/model/、src/network/、src/hw/{tx,rx}/rtl/network/、data/model/、sim/network/。
- 已上板的系统级事实（报告其他章节会写，你可以引用但不要展开）：完整工程布局布线后 TX LUT 52,666 / FF 53,335 /
  BRAM36 104.5 / URAM 10 / DSP 243，WNS +0.151 ns；RX LUT 70,768 / FF 76,845 / BRAM36 123.5 / URAM 25 / DSP 394，
  WNS +0.234 ns；Vivado 估算功耗 TX 4.49 W / RX 4.94 W（PS8 各 2.733 W）。空口实测 30 fps 10 分钟无丢帧；
  PL 计数器分段时延中位数：编码 38.20 ms、空口传输 2.87 ms、解码 30.39 ms。

## 写作要求
- 简体中文，Markdown，公式用 $...$ / $$...$$；表格用 Markdown 表格。篇幅：两节合计约 4000–6000 字。
- 与 v3 相比的改动：v3 写着"本文定量分析不纳入空口指标"，现在系统已完成空口实测，不要再写这类限定；但不要替我写 PHY 与实测。
- 每个数值后面用括号或脚注给出出处（仓库内相对路径优先；仓库里没有的，写 <codex-work>\... 下的路径，我会再处理）。
- 语气平实，不夸张；不要写"首次""业界领先"之类无法证明的话。
- 需要的图：如果你已有合适的图（docs/figures/ 下），把 PNG 复制到 report/figures/network/ 并在文中引用；不要新建复杂绘图。
- 不要修改 report/drafts/codex_network.md 和 report/figures/network/ 以外的任何文件；不要动 <codex-work> 下的任何文件；
  不要运行 Vivado 或长时间仿真。
- 最后在你的回复里列出：用到的数据来源清单，以及你认为不确定、需要我核实的地方。
