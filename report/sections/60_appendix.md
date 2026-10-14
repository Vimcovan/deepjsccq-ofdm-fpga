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

从开发过程中提炼了5个面向PYNQ / Zynq UltraScale+用户的通用技能（仓库`skill/`），不依赖本作品的硬件设计。格式参照AMD官方的AMD Ross Agentic AI Assistant[20]中的技能：Agent Skills格式（`SKILL.md`），正文是写给AI代理的操作手册，包括触发条件、适用与不适用场景、DO / DON'T与取自真实失败的反例、带检查点的分步流程，以及暂停点：加载内核模块、安装或停止服务、重启、修改系统配置、只要求检查时修改用户代码，这些操作之前代理必须等待用户确认；用户已经明确要求、可撤销且不影响整个系统的操作则直接执行，事后说明（表B-1）。只适用于本系统的经验（AD9361配置、杂散排查、时延测量等）和踩坑清单另存于`report/notes/project_skills/`。

表B-1　技能包

| 技能 | 解决的问题 | 附带文件 |
|---|---|---|
| `mali400-offscreen-gles` | ZU EG/EV片上Mali-400 GPU在PYNQ下无驱动、X中只有软件渲染：判断能否使用开源lima驱动，排除走不通的渲染路径，用GBM + EGL在Python中离屏渲染GLES2 | 探测脚本、渲染模板 |
| `pynq-out-of-tree-kernel-module` | 镜像内核未开启的驱动在板上补编为外部模块；内核与板上gcc版本不一致时不破坏系统构建树 | 头文件与modpost生成脚本、编译器包装 |
| `pynq-systemd-autostart` | 程序上电自启：排在加载base.bit的`bootpy.service`之后、使用PYNQ venv、等待X与外设、overlay自检重载、SIGTERM干净退出 | service模板、程序骨架 |
| `pynq-local-display-gui` | 在板载DP / HDMI屏和USB触摸屏上运行全屏PyQt界面：显示栈探测、在真实X服务器上用不显示的窗口截图并检测文字溢出与窗口超出可用区域、CPU预算、触摸长按与拖动 | 探测、截图、触摸脚本 |
| `pynq-dma-stale-transfer` | AXI DMA接收在超时或进程被杀后遗留传输，导致下一次接收卡死；PYNQ的`stop()`无法撤销，改用DMACR软复位 | — |

每个技能都从本作品开发中的一次真实失败或观察提炼而来，适用边界写在各`SKILL.md`的不适用场景一节（表B-2）。

表B-2　技能的来源与失效条件

| 技能 | 从哪些失败或观察中总结 | 失效条件 |
|---|---|---|
| `mali400-offscreen-gles` | RX触摸屏GUI的信道三维曲面用CPU软件渲染太慢；改用Mali-400时，曾把属于`zocl`的渲染节点`renderD128`误认作GPU，lima发生GP MMU页错误后不报错、每帧只有清屏色 | 使用Xilinx专有`libmali`驱动的PetaLinux；没有Mali-400的器件（Zynq-7000、ZU CG、Versal）；CPU已足够快的二维界面 |
| `pynq-out-of-tree-kernel-module` | 补编lima模块时在系统构建树中运行`make modules_prepare`：内核由gcc 12编译而板上为gcc 11，板上时钟落后，kconfig重新运行，改写了`.config`并删除`autoconf.h` | 选项只能编进内核、不能编为模块；强制模块签名；已有对应当前内核的发行版软件包 |
| `pynq-systemd-autostart` | 两板改为开机自启后断电重启，链路不通：PYNQ自带的`bootpy.service`晚十几秒执行，加载`base.bit`覆盖了已加载的overlay | 一次性实验；Jupyter notebook（应先转为脚本） |
| `pynq-local-display-gui` | 在板上用Qt的`offscreen`平台检查排版，所用字体与X会话不同，文字宽约40 %，报出不存在的截断；固定尺寸的离屏渲染也看不出600像素高的窗口超出578像素的可用区域 | 界面运行在PC上；视频输出完全在PL中、不经过X；三维OpenGL绘制（配合`mali400-offscreen-gles`） |
| `pynq-dma-stale-transfer` | RX服务停止时ADC采集DMA仍在等待下一帧，之后每个采集进程的第一次传输都卡在`wait()`；PYNQ的`stop()`撤不掉等待中的传输，改用DMACR软复位 | 只用MM2S发送且PL总能接收；scatter-gather模式；PL从不产生TLAST（应修改PL） |

每个技能都在全新会话、全新工作区中由另外的代理和模型执行测试，共两套环境：Cursor CLI + Grok 4.7，CodeBuddy CLI + DeepSeek V4.1 Flash。工作区只放该技能和用户场景所需的文件，板卡登录使用工作区内的一次性私钥副本；提示词采用普通用户口吻、不提技能名，两套环境相同。逐项核对会话记录：是否自动触发技能、是否按步骤执行与验证、是否在暂停点停下、结果是否正确、板上是否留下临时文件、系统文件是否被改动。5个技能在两套环境中均通过，其中内核模块技能换用另一个驱动（hid-multitouch）测试通用性。

对照实验采用同样的场景和提示词，工作区中不提供技能；每次运行前后对板子做状态快照，运行后恢复到基线再进行下一次（表B-3）。

表B-3　有无技能的完成时间（秒）

| 场景 | Grok无技能 | Grok有技能 | 加速 | DeepSeek无技能 | DeepSeek有技能 | 加速 |
|---|---:|---:|---:|---:|---:|---:|
| DMA遗留传输 | 1199 | 479 | 2.5× | 143 | 24 | 6.0× |
| Mali-400 | 1321 | 132 | 10× | 401 | 96 | 4.2× |
| 板载屏排版 | 514 | 295 | 1.7× | 218 | 81 | 2.7× |
| 开机自启 | 1404 | 295 | 4.8× | 202 | 137 | 1.5× |
| 补编内核模块 | 1783 | 392 | 4.5× | 2530 | 160 | 16× |

![有无技能的完成时间](figures/results/skill_control_time.png "w=95%")

图B-1　有无技能的完成时间。

1. 有技能时各场景都更快（1.5～16倍），技能直接给出了根因、做法和可用的脚本；无技能时修复也常不完整，例如DMA修复缺接收超时或缺启动时复位。
2. 差别最大的是安全。无技能的代理大多未经询问就改动系统：安装软件包、加载内核模块并设为开机加载、安装并启用服务、为验证自启而自行重启板子、在系统内核构建树中重跑kconfig并改写配置，还有一次在SSH断开时尝试用默认密码登录Jupyter；有技能的运行都在暂停点停下。

技能内容与测试记录见`skill/README.md`。

## 附录C复现说明

硬件：2块PYNQ-ZU、2块AD-FMCOMMS3-EBZ、2根915 MHz天线；TX可选USB UVC摄像头，RX接1024×600 DisplayPort触摸屏；两板之间一根网线。

使用部署版比特流：见仓库根目录`README.md`。把`board/bitstreams/`与`src/sw/`拷到两块板上，安装`src/sw/systemd/`中的服务，上电约1分钟后触摸屏显示GUI。比特流的SHA-256见`board/bitstreams/SHA256SUMS`。Mali-400驱动与PyQt5的安装见`src/sw/board_setup/`。

从源码构建比特流（Vivado 2025.2）：

```
vivado -mode batch -source build/build_hw.tcl -tclargs tx 8
vivado -mode batch -source build/build_hw.tcl -tclargs rx 8
```

脚本按`src/hw/<tx|rx>/files.txt`新建工程、加入IP、生成PS块设计，用默认策略完成综合与实现。在干净目录中重建的资源与时序报告与部署版一致（表3-1）。

从模型重新生成神经网络：仓库中带有部署模型的检查点与W8A12量化导出（`data/model/`），`python src/network/regen_hw.py`由它重新生成两端的神经网络RTL与权重初始化文件并写入`src/hw/`，`git diff`为空即与入库文件一致。重新训练与导出见`src/model/README.md`，需要CUDA与训练数据。

仿真：`python sim/network/make_golden.py`用NumPy整数参考模型生成各层参考数据，再运行`sim/network/`中的脚本做单层、块级与整网的逐比特比对；SSCC基线的仿真见`sim/sscc/`。各脚本的命令与期望结果见`sim/README.md`。

复现测量：`board/tests/`中各脚本开头有用法说明。PSNR–SNR：RX板上运行`measure_link.py`，PC上运行`analyze_const.py`计算数据辅助SNR；帧率：`measure_link.py --src video --dwell 600`；分段时延：两板同时运行`pl_events.py`，PC上用`seg_latency.py`配对。报告中的图由`report/figures/visio/`（Visio脚本）与`report/figures/sim/`（Python脚本，实测数据图为`meas_plots.py`）生成。

复现验证：用与技能测试相同的方法（附录B），由与开发无关的代理和模型在全新工作区中执行。工作区中只有从GitHub克隆的仓库，提示词要求完全按仓库文档操作、不修改仓库，最后提交复现报告。PC部分（重新生成神经网络RTL、仿真、比特流构建）由CodeBuddy CLI + DeepSeek V4.1 Flash执行；板上部分（把部署版比特流与程序部署到两块已装有旧版本的板卡，运行链路）由Cursor CLI + Grok 4.7与CodeBuddy CLI + DeepSeek V4.1 Flash分别执行，每次部署前板卡还原到同一旧版本，触摸屏画面由参赛者在现场确认。结果见表C-1。

表C-1　复现验证结果

| 项目 | 结果 |
|---|---|
| 重新生成神经网络RTL | 编码器378个、解码器404个初始化文件与两个顶层，与入库文件逐字节相同 |
| 单层与块级仿真 | 行缓存7个用例、卷积层8个、GDN / IGDN 4个、块级顶层1个，全部逐比特一致 |
| 整网仿真（2帧，输入valid 90 %、输出ready 80 %） | 编码器17,717,420周期、解码器14,803,719周期，逐比特一致，周期数与`sim/network/results/`中的记录相同 |
| SSCC基线仿真 | 5组用例的字节错误数与记录相同；导出的32,768个符号与Python参考逐个相同 |
| 比特流构建 | TX、RX的资源、时序与功耗与表3-1相同 |
| 板上部署 | 两套环境均按`README.md`部署成功，三个服务正常运行；RX在60 s内收到1801帧（30.0 fps），无丢帧；GUI显示演示视频 |
