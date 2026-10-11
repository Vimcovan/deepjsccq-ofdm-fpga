# 附录

## 附录A大模型协作记录

本作品由参赛者与两个AI编程代理协作完成：Claude Code（Anthropic）与Codex（OpenAI）。代理在本机与两块板卡上读写代码，运行Vivado、仿真和板上程序，采集数据并出图；参赛者提出目标和约束、做关键技术判断、决定取舍，并完成接线、上电、观察LED / 屏幕 / 天线等全部物理操作。完整记录见仓库`report/llm_collab/`。

表A-1　分工与时间线（2026年）

| 时间 | 工作 | 代理 |
|---|---|---|
| 09-01 – 09-26 | DeepJSCC原型；DeepJSCC-Q按期刊版重写、训练；类802.11a OFDM发射机 | Codex |
| 09-25 – 09-28 | AD9361配置调试；OFDM自环到两板空口；AGC、定时门限、长帧SFO跟踪、遥测GUI | Claude Code |
| 09-28 – 09-29 | 1200轮训练；定点方案；存储规划；行缓存与卷积引擎RTL | Claude Code |
| 09-29 – 09-30 | 神经网络RTL生成器、FIFO定尺寸、逐比特验证、编 / 解码器工程 | Codex |
| 09-30 – 10-05 | 物理层与神经网络对接；PYNQ上板；摄像头、GUI、Mali-400 GPU；SSCC基线 | Claude Code |
| 10-05 – 10-07 | 演示视频（代理控制两块板卡、配音、剪辑）；AGC看门狗；实测；开源仓库 | Claude Code |
| 10-07 – 10-11 | 设计报告：Codex起草神经网络部分初稿并交叉审查；Claude Code撰写、绘图，参赛者逐条批注修改 | 两者 |

与本项目相关的会话共40个，用户消息766条。`report/llm_collab/cases.md`整理了17个典型案例，每个案例写明背景、模型做了什么、用户做了什么和结果，代表性的几类见表A-2。

表A-2　协作案例（摘选）

| 类型 | 案例 | 结果 |
|---|---|---|
| 参赛者给出关键判断，AI计算与实现 | LTF定时门限按半采样相关峰损失确定；SSCC在悬崖区的增益跳变来自PAPR与ADC过载 | 门限0.375用移位相加实现；AGC锁定电平改为−14 dBFS |
| 参赛者追问依据，纠正AI的错误前提 | 并行度不必受BRAM位宽限制；对openwifi配置的引用不完整 | 加入位宽转换后DSP与BRAM同时下降；补齐漏抄的AGC寄存器 |
| 参赛者约束模块边界 | AGC属于射频模块，不依赖基带；帧缓存归物理层，神经网络不重复设置 | AGC不与基带耦合；神经网络两端改为带反压的AXI-Stream |
| 参赛者纠正测量口径 | PS调度抖动不应计入FPGA的时延与帧率 | 改为PL计数器分段时延 |
| AI发现问题 | SPI握手错位；量化器多乘了一个系数（由参赛者观察到的训练曲线异常引出） | 校准恢复正常；重新训练 |
| 两个代理交叉审查 | Codex审查报告初稿，提出21条意见，其中包括Claude Code写下的过度结论和无出处数值 | 逐条处理，处理记录见`report/llm_collab/claude_codex/` |

AI反复出现的问题有四类：没有证据就下结论；把自己定的经验值当成规格；没有问清约束就增加设计；只读了部分资料就引用。对应的协作约定是：改动要小而有判据，一次只改一处，先定验证标准再动手，不做不必要的RTL修改。这些约定写进了代理的记忆与交接文档，在后续工作中持续生效。会话全文的脱敏转写及生成脚本见`report/llm_collab/transcripts/`与`report/llm_collab/tools/`。

## 附录B技能包

从开发过程中提炼了7个技能（仓库`skill/`），采用Agent Skills格式（`SKILL.md`），可直接被Claude Code / Codex加载。每个技能写明适用场景、使用方法、已验证效果和来源的失败案例（表B-1）。`skill/README.md`另附25条踩坑清单（Vivado、AD9361、PYNQ、测量）。

表B-1　技能包

| 技能 | 内容 | 适用范围 | 来源的失败 |
|---|---|---|---|
| `pynq-dma-stale-transfer` | AXI DMA接收挂起后的软复位 | PYNQ | 新进程抓不到ADC数据，PYNQ的`stop()`撤不掉挂起的传输 |
| `uvc-camera-controls` | 无v4l-utils时用ioctl调摄像头参数 | PYNQ / Linux | 摄像头画面发灰 |
| `touch-without-multitouch` | 读evdev实现长按 / 拖动 | PYNQ + Qt | 内核缺hid-multitouch，触摸屏只有单击 |
| `qt-offscreen-layout-check` | 板上离屏渲染核对小屏排版 | 通用 | 小屏排版问题反复需要人看屏、拍照、描述 |
| `sdr-spur-hunting` | 增益缩放、频率换算、开关源、挪频定位杂散 | SDR | 显示像素时钟的谐波落入915 MHz频带 |
| `ad9361-ps-control-agc` | PS初始化、快速AGC排查、看门狗 | AD9361 | 漏抄寄存器、依赖底噪门限的看门狗误复位 |
| `pl-counter-latency` | PL计数器 + 跨板时钟偏差校正的分段时延 | Zynq | PS抖动混入FPGA时延、帧配对错位 |

## 附录C复现说明

硬件：2块PYNQ-ZU、2块AD-FMCOMMS3-EBZ、2根915 MHz天线；TX可选USB UVC摄像头，RX接1024×600 DisplayPort触摸屏；两板之间一根网线。

使用部署版比特流：见仓库根目录`README.md`。把`board/bitstreams/`与`src/sw/`拷到两块板上，安装`src/sw/systemd/`中的服务，上电约1分钟后触摸屏显示GUI。比特流的SHA-256见`board/bitstreams/SHA256SUMS`。Mali-400驱动与PyQt5的安装见`src/sw/board_setup/`。

从源码构建比特流（Vivado 2025.2）：

```
vivado -mode batch -source build/build_hw.tcl -tclargs tx 8
vivado -mode batch -source build/build_hw.tcl -tclargs rx 8
```

脚本按`src/hw/<tx|rx>/files.txt`新建工程、加入IP、生成PS块设计，用默认策略完成综合与实现。在干净目录中重建的资源与时序报告与部署版一致（表3-1）。

从模型重新生成神经网络：按`src/model/README.md`准备数据、训练、W8A12导出，再用`src/network/`生成各层RTL与权重初始化文件；RTL与整数参考模型的逐比特比对见`sim/network/`。

复现测量：`board/tests/`中各脚本开头有用法说明。PSNR–SNR：RX板上运行`measure_link.py`，PC上运行`analyze_const.py`计算数据辅助SNR、`plot_psnr_snr.m`出图；帧率：`measure_link.py --src video --dwell 600`；分段时延：两板同时运行`pl_events.py`，PC上用`seg_latency.py`配对、`plot_seg_cdf.m`出图。报告中的图由`report/figures/visio/`（Visio脚本）与`report/figures/sim/`（Python脚本）生成。
