## 2.2 DeepJSCC-Q 模型与网络硬件

**模型与训练。** 网络将图像直接映射为有限星座上的复数符号，接收端根据均衡后的连续 I/Q 重构图像。部署配置为主通道数 $C=32$、潜变量通道数 $C_{\rm lat}=16$，输入为 $256\times256$ RGB 图像，总空间下采样倍率为 $4$，潜变量尺寸为 $64\times64\times16$。[^model] 相邻通道配为 I/Q，因此每帧产生 $k=64\times64\times16/2=32768$ 个 64QAM 符号，$\mathrm{spp}=k/(HW)=0.5$；若分母采用 RGB 标量数，则带宽比为 $k/(3HW)=1/6$，两种定义应分开使用。[^model]

编码器模块序列为 RG–RB–RG–ATT–RB–RG–RB–RG–ATT；解码器为 ATT–RB–RU–RB–RU–ATT–RB–RU–RB–RU，最后经 sigmoid 输出图像。RG 是带 GDN 的残差块，RB 是普通残差块；RU 在主路和旁路使用卷积与 PixelShuffle，主路继续执行卷积和 IGDN。只有 `enc.0`、`enc.2` 执行步长为 $2$ 的下采样，只有 `dec.7`、`dec.9` 执行倍率为 $2$ 的上采样，其余 RG/RU 保留运算而不改变空间尺寸。[^model] PixelShuffle 将通道重排到空间位置，上采样倍率为 $r$ 时，卷积先生成 $r^2C_o$ 个通道，再重排为放大的特征图；重排本身不增加可训练权重。注意力块 ATT 的特征支路与门控支路分别包含瓶颈残差单元，先用点卷积收缩通道，再完成空间卷积和通道恢复，按 $\mathbf y=\mathbf x+\mathbf a\odot\operatorname{sigmoid}(\mathbf b)$ 融合。归一化形式为

$$
\operatorname{GDN}(x_i)=\frac{x_i}{\sqrt{\beta_i+\sum_j\gamma_{ij}x_j^2}},\qquad
\operatorname{IGDN}(x_i)=x_i\sqrt{\beta_i+\sum_j\gamma_{ij}x_j^2}.
$$

这里的有效 $\beta$ 已包含实现中防止分母退化的 $\epsilon=10^{-6}$，整数导出时也将其并入偏置项。[^model][^ptq]

![部署网络的模块与张量尺寸](figures/network/fig02_network.png)

图 2　部署网络的编码与解码结构（图内 [2] 即本文参考文献 [2]）。结构、尺寸与当前模型代码及 manifest 对应。[^figures][^model]

训练由 `train_v2.py` 完成，采用 $10\ \mathrm{dB}$ AWGN 信道，损失为重构均方误差加权重 $0.05$ 的星座分布 KL 正则项：[^train]

$$
\mathcal L=\mathrm{MSE}(\mathbf x,\hat{\mathbf x})+0.05D_{\rm KL}(p\|u).
$$

其中 $p$ 为批次内软分配的平均星座概率，$u$ 为均匀分布。星座为 $\{(a+jb)/\sqrt{42}:a,b\in\{-7,-5,-3,-1,1,3,5,7\}\}$，归一化针对均匀星座平均能量。[^train] 前向采用最近星座点硬量化，反向通过距离 softmax 的软量化传递梯度，代码写作 `hard + soft - soft.detach()`。优化器为 Adam，初始学习率 $2\times10^{-4}$，小批量为 $8$，梯度累积后的有效批量为 $16$；部署检查点对应最佳 epoch $1186$。[^train] 硬量化使训练前向与部署符号集合一致，软近似则为编码器提供可用梯度；KL 项抑制符号使用概率过度集中。代码没有对每帧量化符号再作 RMS 归一化，因此固定星座的平均能量约定不等于每帧经验功率严格相同，熵正则对发射波形 PAPR 的影响以实测为准（见 4.2 节）。

**训练后量化与软件精度。** 导出流程对同一浮点检查点执行 W8A12 训练后量化：卷积权重为逐输出通道缩放的有符号 $8$ 位整数，激活为逐张量缩放的有符号 $12$ 位整数。[^ptq] `int_ref.py` 明确规定偏置、舍入、饱和和非线性算术；`export_fpga.py` 导出 manifest、参数与黄金张量，RTL 生成器据此产生初始化文件及模块连接。整数参考模型是逐比特验证依据，浮点模型则用于衡量量化损失。

| 软件评估集合 | 浮点 PSNR / dB | W8A12 PSNR / dB | 损失 / dB（计算值） |
|---|---:|---:|---:|
| DIV2K 验证集 | 31.27[^accuracy] | 31.22[^accuracy] | 0.052[^accuracy] |
| Kodak | 32.65[^accuracy] | 32.59[^accuracy] | 0.062[^accuracy] |

表中各变体使用相同的 $10\ \mathrm{dB}$ AWGN 噪声样本；PSNR 从全部标量像素的汇总 MSE 换算，损失由未四舍五入的数据相减。DIV2K 使用 $256\times256$ 中心裁剪，Kodak 使用原图分辨率，后者验证全卷积软件模型，不能解释为硬件支持任意帧尺寸。[^accuracy] 这些是软件量化精度，空口重构质量由实测章节另行报告。

**逐层流式卷积。** 各层拥有独立计算与局部缓存，按 NHWC 顺序传递激活，并通过 valid/ready 处理反压。卷积引擎每次读取一个窗口元素，广播到 $P$ 条输出通道 MAC 通路；权重 ROM 同时提供对应权重。输出通道分为 $G=\lceil C_o/P\rceil$ 组，逐组重读窗口，结果经串行输出、加偏置、激活和重定标后送至下一级。

这种组织使激活读取带宽不随输出并行度同比增加，代价是每个输出通道组仍需遍历完整窗口。已完成的累加结果暂存在寄存器组中，下游可接收时，上一组的输出与下一组的计算能够重叠。整网流水减少层间整幅特征图的搬运，但不消除残差对齐和重排缓存；较慢支路或下游停顿仍会沿握手链传回上游。[^conv][^branch]

规划器以 $250\ \mathrm{MHz}$、$30\ \mathrm{frame/s}$ 为目标，将窗口读数限制在帧周期预算的 $80\%$ 内，按下式选择满足约束的最小整数并行度：[^planner]

$$
P_l=\min\left\{p\in\{1,\ldots,C_o\}:H_oW_oK_hK_wC_i
\left\lceil\frac{C_o}{p}\right\rceil\le0.8\frac{f_{\rm clk}}{F_{\rm target}}\right\}.
$$

该式约束的是读数工作量，并未计入所有流水启动、输出和反压开销。投影旁路采用主路中心抽头时，其并行度还需匹配主路的通道分组。增加 $P$ 可缩短窗口重读时间，也增加乘法器、权重端口和布线需求，因此各层分别配置。

![输出通道并行卷积引擎](figures/network/fig05_conv_engine.png)

图 3　输出通道并行卷积引擎：窗口广播、并行累加与串行重定标。[^figures][^conv]

累加位宽按 $B_{\rm acc}=B_x+B_w+\lceil\log_2(K_hK_wC_i)\rceil+1$ 生成；MAC 结果在偏置路径扩展为 $48$ 位。重定标先预移位并饱和到 $27$ 位，再乘以逐通道整数尺度 $M$，最后舍入移位并饱和到激活位宽：[^conv]

$$
y=\operatorname{sat}_{12}\!\left(\operatorname{rsr}\!\left[
\operatorname{sat}_{27}(\operatorname{rsr}(a,p))M,s\right]\right).
$$

这里 $a$ 已包含偏置及相应激活；$\operatorname{rsr}(v,s)$ 在右移前加半个最低有效位，再作算术右移，与参考模型保持同一舍入规则。重定标乘法根据结果产生间隔选用串行逻辑或 DSP。

GDN/IGDN 先对整数激活平方、与量化 $\gamma$ 加权求和，再加入 $\beta$ 并移位形成 $D$，整数平方根器计算 $r=\lfloor\sqrt D\rfloor$。GDN 用整数除法得到 $\operatorname{sign}(x)\lfloor |x|2^F/r\rfloor$，IGDN 计算 $xr$，随后进入重定标路径。平方根采用恢复算法，逐步试减并更新余数；除法同样逐位生成商，IGDN 后乘法采用移位加法。多个迭代单元轮询接收任务，按派发顺序回收结果，以兼顾处理间隔与输出顺序。sigmoid 采用 $32$ 段分段线性近似，负半轴利用对称性，门控值采用含单位端点的无符号 Q0.16 表示。[^nonlinear]

**分支复用与片上存储。** RU 将同一输入上的主路、旁路首个卷积按输出通道拼接，共用窗口和引擎，输出后再拆分；ATT 同样合并两支路的首个点卷积。含投影旁路的 RG/RB 则从主路窗口读数中提取中心抽头，送入独立旁路卷积。各支路保留自己的权重与重定标参数，以及必要的对齐 FIFO，最终相加时共同接受反压。[^branch]

![RU、投影残差与ATT的分支复用](figures/network/fig06_branch_reuse.png)

图 4　共享输入分支的局部复用；合并卷积入口不改变名义乘加工作量。[^figures][^branch]

权重 ROM 的逻辑宽度为 $PB_w$，深度为 $\lceil C_o/P\rceil K_hK_wC_i$。生成器在分布式 LUT ROM、宽字分存储体 BRAM ROM、紧密字节打包 BRAM 加位宽转换器之间选择。小 ROM 使用 LUT，大 ROM 比较按原语宽深粒度计算的 BRAM 占用。激活采用按层配置行数的环形缓存、残差延迟 FIFO 和 PixelShuffle 行缓存；较大的缓存迁入 URAM，权重保留原有 ROM 映射。激活可将 $6$ 个 $12$ 位元素组成 $72$ 位字，顺序攒满后整字写入，读端再选择元素。[^memory] 不同层同时工作且读写端口已被占用，不能仅按总位数把所有缓存视为可任意合并的一块存储。

**网络与 PHY 接口及 RTL 验证。** 编码器量化并配对后输出 $24$ 位 `{Q[11:0], I[11:0]}`，I/Q 均为有符号 Q10，每次握手传递一个复符号。边界上的 `tlast` 与 `tuser[0]` 在帧末符号置位；卷积内部流的 `tlast` 则表示当前像素的最后一个通道，`tuser[0]` 表示帧末，二者不可混同。[^interface] 接收端拆分连续 I/Q 并按张量尺寸恢复内部标记，不作星座硬判决，保留信道噪声及均衡残差供解码器处理。

仓库日志记录编码器、解码器各 $2$ 帧逐比特通过，测试复用同一黄金图像，比较数据及边界标记；输入 valid 概率为 $90\%$，输出 ready 概率为 $80\%$。[^sim] 这证明了指定向量及随机握手条件下 RTL 与整数参考的一致性。完成事件之差为编码 $8163532$ 拍、解码 $6521051$ 拍，在 $250\ \mathrm{MHz}$ 下分别为 $32.654128\ \mathrm{ms}$、$26.084204\ \mathrm{ms}$（计算值）。[^sim] 每端只有一个相邻完成间隔，不能把它当作单帧时延或长期空口统计。

## 4.1 网络侧 PPA 优化前后对比

**模型规模调整的可量化范围。** 设计先缩减通道以控制权重需求，再减少空间下采样次数以维持符号预算。普通卷积的权重数和名义 MAC 为

$$
N_w=K_hK_wC_iC_o,\qquad M=H_oW_oN_w,\qquad
k=\frac{HWC_{\rm lat}}{2D^2}.
$$

输入、输出通道同比缩放为原来的 $\alpha$ 倍时，权重变为 $\alpha^2$ 倍；MAC 还需乘输出空间面积之比。故减少下采样本身不构成计算量降低，反而会增大部分中间特征图。原 DeepJSCC-Q 采用总倍率 $16$，本文采用 $4$；保持本文符号预算时，前者数学上对应 $C_{\rm lat}=256$，后者为 $16$。[^architecture] 当前材料没有这两个配置的成对训练、综合结果，不能将该等预算对应点称作已测“论文原配置”。

| 比较项 | 调整前参照 | 当前配置 | 证据性质 |
|---|---|---|---|
| 等符号潜变量 | $16\times16\times256$[^architecture] | $64\times64\times16$[^model] | 按固定输入和符号预算计算 |
| 潜变量逻辑容量 | 96 KiB[^architecture] | 96 KiB[^architecture] | 假设均按 12 位存储[^architecture]；不是实际缓存占用 |
| 全网权重、MAC、存储资源 | 未单独测量 | 见下文导出统计与资源报告 | 不填补不存在的宽模型测量值 |

当前编码器、解码器分别含 $55/59$ 个卷积算子，可训练参数分别为 $141584/245704$。[^counts] 按导出形状统计，名义卷积工作量分别为 $0.912785408/1.417216000\ \mathrm{GMAC/frame}$。[^counts] 此计数包含普通卷积填充位置，不包括归一化、激活、重定标、传输及控制；参数数也不能直接等同于权重 ROM 字节数。

| 当前模型的卷积权重 | 数量 | 按 FP32 存储 → 按 W8 存储 / B（计算值） |
|---|---:|---:|
| 编码器 | 137024[^counts] | 548096 → 137024[^counts] |
| 解码器 | 241105[^counts] | 964420 → 241105[^counts] |

该表仅改变同一组权重的存储位宽，反映量化的逻辑载荷收益，不是通道缩减前后的模型对比，也不是 FPGA 原语占用。偏置、GDN/IGDN 参数、重定标系数及 ROM 填充另计。权重存储由核形状与通道数决定，激活缓存还取决于空间尺寸、流水相位和端口组织；即使潜变量总容量不变，各层所需行缓存也未必相同。

**并行度与分支复用。** 以下“统一并行度”是可复算的配置参照，并非曾经综合的版本：保持当前合并后的引擎，分别用该端最大并行度作统一上限，且令各层 $P'_l=\min(P_{\max},C_{o,l})$，避免计入超过输出通道数的空通路。[^parallel]

| 项目 | 统一／复用前 | 按层／复用后 | 数值边界 |
|---|---:|---:|---|
| 编码器 MAC 通路之和，统一上限 32[^parallel] | 1120[^parallel] | 217[^parallel] | 配置计算值 |
| 解码器 MAC 通路之和，统一上限 52[^parallel] | 1191[^parallel] | 296[^parallel] | 配置计算值 |
| 编码器卷积算子数 → 引擎数 | 55[^parallel] | 53[^parallel] | 合并 ATT 入口后的结构统计 |
| 解码器卷积算子数 → 引擎数 | 59[^parallel] | 53[^parallel] | 合并 RU、ATT 入口后的结构统计 |

解码器不能简单套用编码器的统一上限：`dec.7.conv+skip` 合并后的输出通道为 $256$，规划需要 $P=52$。[^parallel] 表中的通路数未计入 GDN、重定标等运算，不能称为综合 DSP 节省值。分支合并保持权重与名义 MAC 不变，主要减少重复窗口、输入缓冲和控制；中心抽头旁路仍保留独立引擎。统一并行度以及关闭分支复用后的独立综合、时序和功耗均**未单独测量**。

**BRAM 与 URAM 分配。** 下表从当前 manifest 的 ROM 和激活缓冲明细求和。迁移前假设所有列出的激活缓存均使用其规划 BRAM 映射；迁移后采用 manifest 的 `loc` 配置，权重映射保持不变。两列均是原语粒度规划值，最终综合结果单独列出。

| 网络核 | 权重 BRAM36 等效 | 激活 BRAM36：迁移前 → 后 | 总 BRAM36：迁移前 → 后 | 迁移后 URAM | 最终 OOC BRAM36 / URAM |
|---|---:|---:|---:|---:|---:|
| 编码器 | 41.5[^memory] | 72.5 → 56.0[^memory] | 114.0 → 97.5[^memory] | 4[^memory] | 100.0 / 4[^ooc] |
| 解码器 | 67.0[^memory] | 82.0 → 32.5[^memory] | 149.0 → 99.5[^memory] | 18[^memory] | 100.0 / 18[^ooc] |

迁移分别释放规划 BRAM36 等效块 $16.5/49.5$（计算值），代价是增加 URAM 使用。[^memory] 规划与综合存在原语打包及外围逻辑差异，不能把“全 BRAM 规划值 → 最终 OOC 值”标为一项优化的实测收益。迁移按单位 URAM 可释放的 BRAM 数排序，把较大的激活缓冲优先放入 URAM；这解决的是器件内不同存储资源的供需匹配，不意味着总存储位数或物理面积按同样比例下降。

已有行缓存单模块的成对 OOC 综合可作为局部实测对照。两版共同参数为 $W=H=128$、$C=32$、数据位宽 $12$、打包数 $6$、通道组数 $1$，仅 `RAM_STYLE` 从 `block` 改为 `ultra`。[^buffer-ooc]

| 单模块综合指标 | BRAM 版 → URAM 版 |
|---|---:|
| LUT | 560 → 555[^buffer-ooc] |
| FF | 451 → 450[^buffer-ooc] |
| BRAM36 | 4 → 0[^buffer-ooc] |
| URAM | 0 → 1[^buffer-ooc] |
| 综合 WNS / ns | +0.893 → +0.893[^buffer-ooc] |

这组报告确认所选缓存可迁移到 URAM，局部逻辑开销接近且综合时序裕量相同。它不能代表整核迁移后的布局布线结果：完整网络还包含不同形状的缓存、分支 FIFO 和控制逻辑，互连负载也不同。整核的迁移前版本、权重 ROM 映射消融及各项独立功耗仍未单独测量。

![并行预算和片上存储映射](figures/network/fig07_memory.png)

图 5　并行度、权重宽深形状与激活存储的联合规划。[^figures][^memory]

**与相关实现的对照**见 4.5 节。按同一名义 MAC 定义，[3] 的参考网络编码、解码端各为 $0.110886912\ \mathrm{GMAC/frame}$（转置卷积按输入位置计数），本文编码、解码工作量分别约为其 $8.23/12.78$ 倍（计算值）。这是任务规模之比，不是加速比；而本文网络核的 DSP 与 BRAM 块数仍少于 [3] 的对应端（解码核 LUT、FF 更高，并额外使用 URAM），说明资源没有随网络复杂度同比增长。由于网络、精度、器件和外围范围都不同，该对照不是同模型消融，不能把差异归因于某一项优化。[^counts][^reference]

[^model]: `src/model/deepjsccq_model.py` 的 `Encoder`、`Decoder`、`ResidualBlock`、`ResidualBlockWithStride`、`ResidualBlockUpsample`、`AttentionBlock`；`data/model/manifest.json` 的 `model`、`tensors`、`format.latent_pairing`。符号数与 spp 由张量形状计算。
[^train]: `src/model/train_v2.py` 的训练损失；`src/model/deepjsccq_model.py` 的 `QAM`；`data/model/checkpoint/args.json`、`data/model/checkpoint/summary.json` 的训练参数及 `best_epoch`；`data/model/manifest.json` 的 `epoch`。
[^ptq]: `data/model/manifest.json` 的 `format`、`arithmetic`；`src/model/int_ref.py`、`src/model/export_fpga.py`、`src/network/gen_rtl_init.py`、`src/network/gen_rtl_top.py`。
[^accuracy]: `data/model/manifest.json` 的 `accuracy_db`：DIV2K 浮点 `31.270518898644845`、整数 `31.218744726304347`；Kodak 浮点 `32.64783660001585`、整数 `32.585636513121266`。评估协议见 `src/model/ptq_int16.py` 的 `Evaluator.run` 和 `src/model/export_fpga.py`。训练 summary 的最佳分数属于另一运行，不用于相减。
[^planner]: `src/network/memory_plan.py` 的 `Planner.p_min`、`Planner.engine`、`Planner.snoop`；`data/model/manifest.json` 的 `memory_plan.fclk_hz`、`fps` 和各引擎 `P/groups`。
[^conv]: `src/hw/tx/rtl/network/rtl/conv_engine.sv` 的 `ACC_W`、偏置和重定标路径；`data/model/manifest.json` 的 `arithmetic.conv`、`rsr(v,k)`、`sat(v,n)`。
[^nonlinear]: `src/hw/tx/rtl/network/rtl/gdn_unit.sv`、`axis_gdn.sv`、`axis_sigmoid.sv`；`src/model/int_ref.py`；`data/model/manifest.json` 的 `arithmetic` 和 sigmoid 参数。
[^branch]: `src/network/gen_rtl_top.py`；`src/hw/tx/rtl/network/rtl/centre_tap.sv`、`blk_enc_0_latent_idx.sv`；`src/hw/rx/rtl/network/rtl/blk_rx_in_output.sv`；`data/model/manifest.json` 的 `memory_plan.*.engines[].ops`。
[^memory]: `data/model/manifest.json` 的 `memory_plan.encoder/decoder`：引擎 ROM 的 `b18`、激活 `buffers` 的 `b18/loc/uram`；`src/network/memory_plan.py`；`src/hw/tx/rtl/network/rtl/rom.sv`、`rom_banked.sv`、`weight_stream.sv`、`sdp_ram.sv`。迁移前激活 BRAM36 为全部缓冲 `b18` 之和除以二，迁移后只求和 `loc=BRAM` 项；均为计算值。
[^buffer-ooc]: `build/reports/network/synth_line_buffer.tcl`（`enc1_conv1_block` / `enc1_conv1_uram` 配置）与同目录 `enc1_conv1_{block,uram}.{util,timing}.rpt`。Vivado 2025.2、器件 `xczu5eg-sfvc784-1-e`，状态 Synthesized。
[^interface]: `data/model/manifest.json` 的 `format.phy_interface`；`src/hw/tx/rtl/network/rtl/qam_tx.sv`、`axis_line_buffer.sv`；`src/hw/rx/rtl/network/rtl/rx_frame.sv`。
[^sim]: `sim/network/results/encoder_xsim_20260930.log`、`decoder_xsim_20260930.log` 的 `frame ... done` 与 `PASS` 行；`sim/network/tb_top.sv`。完成周期分别为编码 `9553688/17717220`、解码 `8282468/14803519`。
[^architecture]: 由本文 $H=W=256$、$k=32768$ 按 $C_{\rm lat}=2kD^2/(HW)$ 推算；两种潜变量均有 $65536$ 个实数，按 $12$ 位计算为 $786432$ 位，即 $96$ KiB。宽配置没有配套的训练与综合基线。原 DeepJSCC-Q 的下采样倍率见文献 [2]。
[^counts]: `data/model/manifest.json` 的 `ops` 中卷积形状逐项计数与求和，卷积权重数由 `ops[].files.weight.count` 汇总；同一权重集合按 FP32 或 W8 存储时分别乘四或乘一字节，均为计算值。参数数包含卷积权重、偏置及 GDN/IGDN 的 gamma、beta。总参数与 `data/model/checkpoint/summary.json` 相符。
[^parallel]: 由 `data/model/manifest.json` 的 `memory_plan.encoder/decoder.engines` 计算，排除 `note` 含 `GDN` 的归一化引擎：当前 $\sum P$；统一参照 $\sum\min(\max P,C_o)$。算子数为各卷积引擎 `ops` 数之和，引擎数为条目数；中心抽头条目仍计作独立引擎。参照无综合报告，不能换算为实测 DSP、LUT 或功耗。
[^ooc]: `build/reports/network/blk_enc_0_latent_idx.{util,timing}.rpt`（编码器）、`blk_rx_in_output.{util,timing}.rpt`（解码器）；Vivado 2025.2，`xczu5eg-sfvc784-1-e`，OOC 综合（Synthesized）。
[^reference]: 文献 [3]：网络结构见其 Fig. 2，资源见其 Table II。名义 MAC 按其公布的层形状、以与本文相同的定义计算。文献未说明资源是否为独立网络核范围；URAM 未报告不代表为零。
[^figures]: 网络部分的修订图，原样复制到 `report/figures/network/`，未修改图内数据。
