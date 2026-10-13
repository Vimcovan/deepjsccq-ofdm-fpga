# Claude Code 会话 · 2026-09-28 – 2026-09-28

用户消息 20 条，助手回复 42 段。由 `report/llm_collab/tools/export_transcripts.py` 从原始记录压缩、脱敏生成。

---
### 用户 · 2026-09-28 02:40

> 把这个文件夹："<codex-work>\DeepJSCC-Q"的内容拷贝到工作区中，然后做一次摸底

<details><summary>工具调用 × 2</summary>

- `Bash` Inspect source folder size and contents
- `Bash` Check free disk space and big subfolders

</details>

**助手：**

Space is plenty (568G free). Starting a full copy in the background (including the 11G of Flickr2K data) while I read the code at the same time.

<details><summary>工具调用 × 5</summary>

- `PowerShell` Copy the whole project folder into the workspace
- `Bash` Read README and handoff doc
- `Bash` Read model and training script
- `Bash` Read quantization scripts
- `Bash` Verify copy result and file counts

</details>

**助手：**

The copy is done: 3226/3226 files, 11.16 GB, 0 failures (robocopy exit code 1 means "files copied successfully"). Now looking at the results in runs.

<details><summary>工具调用 × 7</summary>

- `Bash` List run directories and training summaries
- `Bash` Read invalid markers and PTQ/QAT reports
- `Bash` Summarize PTQ and QAT reports compactly
- `Bash` Check eval outputs, datasets, env, hardcoded paths
- `Bash` Check environment and best float checkpoint loads
- `Write` ~\.claude\projects\D--ClaudePrj-DeepJSCC-Q\memory\project-origin-and-external-deps.md
- `Write` ~\.claude\projects\D--ClaudePrj-DeepJSCC-Q\memory\MEMORY.md

</details>

**助手：**

我已经把整个文件夹拷进了工作区，也把代码、训练记录和量化结果都过了一遍。主线模型和结果比较扎实，但离"能部署的全定点版本"还有一段关键距离，下面分项说。

## 拷贝结果

`<codex-work>\DeepJSCC-Q` 拷到了 `<work>\DeepJSCC-Q`，共 3226 个文件、11.16 GB，没有失败项。其中 Flickr2K 数据约 11 GB，训练结果（runs）271 MB。

有两样东西不在这个文件夹里，拷贝没有带过来，代码里还写死了这些路径：
- **Python 环境**：`<codex-work>\DeepJSCC\DeepJSCC_retrain_bundle_20260901\.venv`。我试过，PyTorch 2.9 能用，GPU 也能用。
- **DIV2K 训练集和验证集**：在同一个 bundle 的 `data\DIV2K\` 下。

另外这不是 git 仓库，没有版本记录。

## 项目在做什么

项目按 2022 年 JSAIT 论文版的 DeepJSCC-Q 做 FPGA 精简版，编码器和解码器各放一块 ZU5EG。这一版不带 AF 模块，也不输入 SNR。
- 网络：内部 32 通道，输出 16 通道，编码器下采样两次，得到 64×64×16 的 latent，参数 38.7 万。
- 发送端：64-QAM 硬量化，训练时用直通梯度。
- 接收端：解码器直接吃连续的 I/Q 样本，不做最近星座点判决。

[HANDOFF_DEEPJSCC_Q_JSAIT_FPGA.md](HANDOFF_DEEPJSCC_Q_JSAIT_FPGA.md) 讲的是更早一次、在 E: 盘上失败的尝试，里面提到的文件都不在这个文件夹里。现在这个文件夹是交接之后重新做的版本，已经按交接文档的要求改正了（去掉 AF，接收端不做硬判决）。

## 实验结果（信道 SNR 都是 10 dB）

| 实验 | 结果 | 能不能用 |
|---|---|---|
| `float_fpga_c32_cout16_paperqam_df2k`，训了 1200 轮，最好的是第 1179 轮 | DIV2K 验证集 31.04 dB，Kodak 32.40 dB | **当前主线浮点模型** |
| `*_corrected`、`*_df2k` | 28.1 / 29.6 dB | 目录里已标注作废：多做了一步论文里没有的逐图 RMS 归一化 |
| `float_fpga_c32_cout16`、`*_long` | 21.3 / 23.5 dB | 早期训练太短，README 里的 21.30 dB 就是它，已经过时 |
| `ptq_w8a8_paperqam*`，训练后直接量化 | Kodak 30.8 dB（掉 1.6 dB）；其他几种变体掉 1.7 到 5.6 dB | 都没达到"只掉 1 dB"的目标 |
| `qat_w8a8_paperqam` 和 `_gdn8`，量化感知训练 | Kodak 31.16 dB（掉约 1.24 dB），验证集 30.05 dB | **当前最好的 W8A8 候选** |

GDN 参数用 8 位还是 18 位，结果几乎一样，所以 8 位就够了。

## 发现的问题

1. **还没有实现真正的全整数推理。** [export_qat_fixed.py](export_qat_fixed.py) 只导出了整数参数和缩放系数，它自己也写明了缺口：注意力和输出层的 sigmoid、GDN/IGDN 里的开方和倒数开方仍然是浮点。量化训练也只是在浮点卷积后面模拟量化，所以现在的 31.16 dB 不能算整数推理的实测结果。
2. **有三处结构和它引用的 CompressAI 模块写法不一致**，都在 [deepjsccq_model.py](deepjsccq_model.py)：
   - GDN 参数经过 softplus 后，非对角项初始值约 0.69，CompressAI 的写法初始接近 0，相当于通道之间一开始就强耦合。
   - 注意力模块的小单元里少了内部跳连和 ReLU。
   - `ResidualBlock` 的激活函数放在相加之后，CompressAI 是在相加之前。

   这些对已经训好的模型不致命，但如果要严格对齐论文的 Fig. 3 结构，需要决定改不改。
3. **SNR 课程表按小批次计步，不是按参数更新计步。** 论文里 σ_q 每 1 万次参数更新加 5；这里每 2 个小批次才更新一次参数，所以 σ_q 实际涨得快了一倍。
4. **两套量化脚本的缩放系数取法不一样。** 训练后量化的激活缩放是把 log2 四舍五入，可能比需要的小，导致截断；量化训练的权重缩放是向上取整。量化训练直接沿用了前者的缩放表。
5. **路径写死在旧位置。** 量化训练脚本会从 checkpoint 里读回训练数据路径，而这个路径指向 `<codex-work>\...\Flickr2K`，拷贝后它仍然会去读旧目录。
6. **临时文件比较多**：`cmp_*.py`、`diag_*.py`、`debug_ptq.py`、`test_pc.py`、`pc.out/err`、`__pycache__`，以及只跑了 1 轮的 `profile_after_workers`。

## 建议的下一步

1. 先把工作区变成独立可跑：`git init`，把写死的路径改成相对路径或命令行参数，整理掉临时文件。
2. 决定第 2 条的结构偏差要不要改。改的话要重新训浮点模型，按以前的速度要几十个小时；不改就直接在第 1179 轮的模型上继续往下做。
3. 补上真正的全整数推理：为 sigmoid、开方和倒数开方定义定点近似，做一个 NumPy 或 C 的逐比特参考实现，确认 PSNR，再生成给 RTL 用的 golden vector。

你想先从哪一步开始？

另外我存了一条记忆：记下了这个项目是从哪里拷来的，以及外部的 Python 环境和数据位置。

### 用户 · 2026-09-28 02:45

> 你发现的这几个问题会对训练效果影响很大吗？另外你可以看看DeepJSCC-Q原论文，有早期版本和最终版，CompressAI不确定是按照哪一版来的，还是以论文最终版为准

<details><summary>工具调用 × 6</summary>

- `ToolSearch` 
- `Bash` Download both DeepJSCC-Q papers from arXiv
- `Read` ~\AppData\Local\Temp\claude\D--ClaudePrj-DeepJSCC-Q\27923880-d43b-434a-9cdf-14a0d7f7dc1f\scratchpad\final.pdf
- `Read` ~\AppData\Local\Temp\claude\D--ClaudePrj-DeepJSCC-Q\27923880-d43b-434a-9cdf-14a0d7f7dc1f\scratchpad\early.pdf
- `Read` ~\AppData\Local\Temp\claude\D--ClaudePrj-DeepJSCC-Q\27923880-d43b-434a-9cdf-14a0d7f7dc1f\scratchpad\final.pdf
- `Read` ~\AppData\Local\Temp\claude\D--ClaudePrj-DeepJSCC-Q\27923880-d43b-434a-9cdf-14a0d7f7dc1f\scratchpad\final.pdf

</details>

**助手：**

Both papers are read; now I'm checking the vendored CompressAI source and measuring the current model's constellation usage, to put numbers behind the impact estimates.

<details><summary>工具调用 × 2</summary>

- `Bash` Inspect CompressAI attention, residual block, GDN
- `Bash` Probe trained model constellation usage and GDN params

</details>

**助手：**

Found something important: the actual transmit power is 1.218, not 1. Measuring how much this inflates the PSNR:

<details><summary>工具调用 × 3</summary>

- `Bash` Evaluate Kodak PSNR at power-corrected SNR
- `Write` ~\.claude\projects\D--ClaudePrj-DeepJSCC-Q\memory\final-paper-is-authority.md
- `Bash` Add memory index entry

</details>

**助手：**

我上次列的那几个问题，影响都不大；但对照最终版论文，我发现了一个更大的新问题：发射功率超标，而且缺了论文里的 KL 正则项。

## 两版论文和 CompressAI 的关系

先说结论：CompressAI 不属于任何一版论文。两版论文的网络积木都是同一套，跟 CompressAI 的写法一致：
- 两版结构图里残差块、下采样残差块、PixelShuffle 上采样块的画法完全一样。
- 注意力模块两版都只引用了 Cheng 等人 2020 年的论文，而 CompressAI 的 `AttentionBlock` 正是那篇论文的实现。

真正区分两版的不是积木，而是这几点：

| | 2021 早期版 | 2022 JSAIT 最终版（以此为准） |
|---|---|---|
| AF 模块、SNR 输入 | 有 | 无 |
| σ_q（软量化的"硬度"） | 固定为 100 | 从 5 开始逐步加大（论文式 22） |
| 64-QAM 的 KL 正则 λ | 0 | **0.05**（只有 4096-QAM 及以上才取 0） |
| 发射功率 | 希望平均功率接近 1 | 式 (1) 明确要求平均功率 ≤ P̄ = 1 |
| 数据 | CIFAR-10 | ImageNet 128×128 随机裁剪，在 Kodak 上测试 |

## 新发现的问题：功率超标，PSNR 被高估了约 0.3 dB

我用当前最好的浮点模型（第 1179 轮）在 Kodak 上实测了发射的星座点：
- **实际平均发射功率是 1.218，不是 1**，超出论文式 (1) 的约束 0.86 dB。
- 原因是模型偏爱外圈星座点：外圈点被选中的比例是 54%，均匀使用时应为 44%。这等于偷偷提高了信号功率。
- 代码里没有论文式 (21) 的 KL 正则项，没有任何东西约束它这样做。

按真实功率换算，信道 SNR 实际只有 9.14 dB。在这个 SNR 下，Kodak PSNR 从 **32.40 dB 降到 32.12 dB**，也就是虚高约 0.29 dB。

这是最该修的一条：它影响的是结果能不能公平对比，而不只是效果好坏。

## 上次那几条问题的影响估计

| 问题 | 最终版论文的依据 | 预估影响 |
|---|---|---|
| 缺 KL 正则、功率不受约束 | 论文式 (1)、式 (21)，64-QAM 用 λ=0.05 | 实测虚高 0.29 dB，**要修** |
| 注意力模块的小单元少了内部跳连和 ReLU | 论文引用的 Cheng 2020 就是这样写的 | 估计 0.1–0.3 dB，没实测过 |
| 训练设置不同：学习率 2e-4 且不衰减、有效批大小 16、Adam β2=0.999 | 论文是学习率 1e-4 加平台期衰减、批大小 32、β2=0.99 | 估计 0.2–0.5 dB，主要影响收敛质量 |
| GDN 参数的初始化方式 | CompressAI 的写法 | **很小**。训练完后非对角项已经学到 0.02 到 0.65，说明主要影响前期收敛 |
| `ResidualBlock` 在相加之后才做激活 | 论文图 3 和 CompressAI 都是先激活再相加 | 很小，估计 ≤ 0.1 dB（负斜率只有 1/128） |
| σ_q 的计步方式导致涨速快一倍 | 论文式 (22) | 可以忽略。σ_q 大约在第 440 轮就到 100 封顶，之后没有区别 |

还有一点要说明：论文图 3 的上采样残差块里画的是 GDN，而 CompressAI 和当前代码用的是逆 GDN。解码器里用逆 GDN 是惯例，我倾向于保留，这里只是记一笔。

上次提到的量化缩放取法和写死路径这两条，不影响浮点训练，只影响后面的定点化和运行。

## 和论文结果的差距

论文图 12 在同样条件下（64-QAM、SNR 10 dB，带宽比 ρ=1/6，与我们一致），Kodak 约 **34.9 dB**。我们修正功率后是 32.1 dB，差约 2.8 dB。

大部分差距应该来自内部通道数少了 8 倍（32 对 256）。上面这些实现上的差异合计大概能挽回 0.3–0.8 dB。不过这只是估计：没做对比实验，拆不开这两部分的贡献。

## 建议

把以下几项一起改掉，然后重训一次：
- 加上 KL 正则（λ=0.05），并按实际功率换算 SNR；
- 注意力小单元补回跳连和 ReLU；
- `ResidualBlock` 改成先激活再相加；
- GDN 改成 CompressAI 的参数化写法；
- σ_q 改成按参数更新计步；
- 学习率和优化器参数改成论文的设置。

这些改动对 FPGA 几乎不增加开销（补回的只是加法和 ReLU）。按之前每轮约 42 秒算，1200 轮要十几个小时。如果想先确认值不值得，可以每组先跑约 200 轮，对比"只加 KL"和"全部改"两组，再决定要不要跑完整训练。

要我按这个方案修改代码吗？

测量脚本在草稿目录里：`probe.py` 统计星座点使用情况，`snr_fair.py` 做功率换算后的评估。另外我把"以最终版论文为准"记进了记忆。

### 用户 · 2026-09-28 02:50

> 先跑200轮对比实验，只加KL和全部改两组。另外之前的训练速度太慢，而且GPU使用率很低，瓶颈完全不在GPU，你先想想办法能不能把速度提上来

<details><summary>工具调用 × 1</summary>

- `Bash` Check GPU, CPU, RAM, disk hardware

</details>

**助手：**

Hardware: RTX 5060 Ti 8G, i5-14600KF (14 cores, 20 threads), 32G RAM, NVMe SSD. Measuring the data-loading time and the GPU compute time separately:

<details><summary>工具调用 × 2</summary>

- `Bash` Profile PNG decode vs GPU step throughput
- `Bash` Add paper-architecture switches and KL probs to model

</details>

**助手：**

Now the cache preprocessing script:

<details><summary>工具调用 × 2</summary>

- `Write` <work>\DeepJSCC-Q\prepare_cache.py
- `Bash` Build decoded image cache for training

</details>

**助手：**

While the cache builds, I'll write the new training script:

<details><summary>工具调用 × 2</summary>

- `Write` <work>\DeepJSCC-Q\train_v2.py
- `Bash` Verify cache correctness and legacy model reproduction

</details>

**助手：**

The cache checks out: it is byte-identical to the PNGs, and the old model reproduces 32.40 dB (Kodak) and 31.04 dB (validation). Next, a speed test of both configurations:

<details><summary>工具调用 × 1</summary>

- `Bash` Benchmark epoch time for both configs

</details>

**助手：**

Epoch time dropped from 42 s to 12–18 s, and data wait is only 0.1 s per epoch, so the bottleneck is now the GPU. Quick check of where the GPU time goes:

<details><summary>工具调用 × 4</summary>

- `Bash` Profile encoder/quantizer/decoder GPU time
- `Bash` Show current quantizer code
- `Bash` Implement separable quantizer and verify equivalence
- `Bash` Launch both 200-epoch comparison runs

</details>

### 用户 · 2026-09-28 03:02

> [Request interrupted by user for tool use]

### 用户 · 2026-09-28 03:04

> 现在只是训练浮点模型，没有加入QAT吧

**助手：**

对，只训练浮点模型，没有加 QAT。

- **`train_v2.py`**：这是新写的训练脚本，纯 float32 训练，训练时用混合精度（AMP）提速。里面没有任何伪量化、定点化或 QAT 的内容。
- **两组对比**：比较的都是浮点结果。一组是"旧设置 + KL"，另一组是"论文最终版全部改"。
- **信道部分**：64-QAM 发送端的硬量化是论文本身的调制步骤，和权重、激活值的 W8A8 量化是两回事。
- **旧的 QAT 脚本**：`qat_w8a8.py` 等旧脚本没有改动，还是按旧的 GDN 写法写的。等新的浮点模型定下来之后，要先适配新结构才能接着做 PTQ/QAT。

刚才两组训练的启动命令被你中断了，所以现在没有训练在跑。已经完成的是：
- 解码缓存 `data/cache`，27G，已确认和原图逐像素一致；
- 模型的论文结构开关，默认值仍是旧结构，旧 checkpoint 加载后能复现 32.40 dB；
- 等价的快速量化器；
- `train_v2.py`。

速度上，每轮从 42 秒降到约 12–18 秒；QAM 量化器提速之后应该还能再快一些，这点还没实测。

要我现在启动这两组 200 轮的浮点对比实验吗？还是你想先调整某组的设置？

### 用户 · 2026-09-28 03:05

> 好的，启动两组对比实验

<details><summary>工具调用 × 4</summary>

- `Bash` Launch both 200-epoch comparison runs
- `ToolSearch` 
- `Bash` Wait for first epochs and check GPU usage
- `Bash` Show latest log lines of both runs

</details>

**助手：**

The paper-architecture group went NaN, so I'm stopping it to investigate. The KL-only group is also unexpectedly slow at 60 s per epoch.

<details><summary>工具调用 × 3</summary>

- `Bash` Stop paper-arch run and view its CSV
- `Bash` List running python processes
- `Bash` Kill all training processes and clean run dirs

</details>

**助手：**

Now reproducing the NaN on its own. I'll run the paper-architecture config step by step, recording where the first non-finite value appears:

<details><summary>工具调用 × 3</summary>

- `Bash` Reproduce and locate NaN in paper-arch training
- `Bash` Force fp32 quantizer and rerun NaN check
- `Bash` Read NaN-check output

</details>

**助手：**

Waiting for the check to finish (it prints after 800 steps).

<details><summary>工具调用 × 2</summary>

- `Bash` Wait for NaN-check output
- `Bash` Kill leftovers; add NaN and double-launch guards

</details>

**助手：**

Relaunching both groups, one copy each:

<details><summary>工具调用 × 4</summary>

- `Bash` Run group A: legacy settings plus KL
- `Bash` Run group B: all paper changes
- `Bash` Wait for first epochs and verify single copies
- `Bash` Get old-run baseline at 200 epochs

</details>

**助手：**

两组对比实验已经重新启动，现在正常在跑。不过第一次启动时出了两个问题，先说明一下。

**第一次启动的问题（已修复）**
- **重复运行**：你中断的那次启动命令其实已经在后台跑起来了，我随后又启动了一次，所以每组都跑了两份。两份互相覆盖日志，速度也被拖慢。我已经全部停掉，清空目录后重新各启动一份。
- **全改组出现 NaN**：原因不在论文结构，而是 KL 项在混合精度下溢出。计算星座点概率的 `einsum` 在 AMP 里用 fp16 算，对 32×32768 个符号求和超过了 fp16 上限 65504，第一步 KL 就变成 inf，随后扩散成 NaN。
  - 修复：量化器整体强制用 fp32。修复后跑了 800 步都稳定。
  - 只加 KL 那组批大小是 8，也有同样隐患，这次一并解决了。
- **两道保护**：给 `train_v2.py` 加了两道保护：loss 一旦出现 NaN 或 inf 立即报错退出；输出目录里已有训练记录时拒绝启动，防止再出现重复运行互相覆盖的情况。

**现在的情况**

| 组 | 目录 | 当前每轮耗时 |
|---|---|---|
| 旧设置 + KL | `runs/cmp200_kl_only` | 53 秒 |
| 论文最终版全改 | `runs/cmp200_paper_all` | 12.7 秒 |

- 只加 KL 那组现在慢，是因为批大小只有 8，每一步都有 CPU 等 GPU 的同步，和另一组抢 GPU 时吃亏。全改组大约 40 分钟后跑完，它单独跑时应该能回到 15 秒左右一轮。
- 预计两组总共约 1.5 小时跑完。
- 两组都引入了 KL 项之后，发射功率已经回到 1.02 到 1.07，星座熵接近满值 6 bit，说明 KL 在起作用。

**参照基线**：旧的主线训练在第 200 轮时验证集是 27.65 dB，前 200 轮最好是 27.88 dB。这个数是名义 SNR 下的值，没有做功率修正。

两组跑完后，每组会自动在 Kodak 上评估，给出名义 PSNR、功率修正后的 PSNR 和实际发射功率。收到完成通知后我会整理对比结果给你。

<details><summary>工具调用 × 1</summary>

- `Bash` Read group B summary and progress of group A

</details>

**助手：**

The full-paper group has finished. The KL-only group is at epoch 51 of 200; running alone it's back to 14–16 s per epoch, so it should finish in about 40 minutes.

**Full-paper group, after 200 epochs:**

| Metric | Value |
|---|---|
| Validation PSNR, nominal = power-corrected | 27.70 dB (best at epoch 198, still rising) |
| Kodak PSNR, nominal / power-corrected | 28.80 / 28.80 dB |
| Actual transmit power | 0.99 on validation, 0.98 on Kodak (constraint satisfied) |
| Constellation entropy | 6.00 bit (all 64 points used almost uniformly) |

- The learning rate never decayed, because validation loss kept improving every epoch. σ_q only reached 15 by the end: counted per parameter update, batch 32 gives only about 21,600 updates in 200 epochs.
- At the same epoch count, the full-paper group is close to the old run (27.65 dB at epoch 200) and slightly behind the KL-only group so far (24.95 vs 25.26 dB at epoch 50). But it uses half the learning rate and a quarter of the updates, so this comparison is confounded by the training settings. I'll lay this out properly once the KL-only group finishes.

### 用户 · 2026-09-28 04:37

> 后面你的回答请使用中文

<details><summary>工具调用 × 2</summary>

- `Write` ~\.claude\projects\D--ClaudePrj-DeepJSCC-Q\memory\reply-in-chinese.md
- `Bash` Add memory index entry and check group A progress

</details>

**助手：**

好的，后面都用中文回答，这个偏好我也记进记忆了。

"只加 KL"那组已经跑到第 195 轮，验证集是 27.64 dB，大约 1 分钟后结束，结束时会自动做 Kodak 评估。

先把全改组的结果用中文重述一遍：

| 指标 | 数值 |
|---|---|
| 验证集 PSNR（名义值与功率修正值相同） | 27.70 dB（第 198 轮最好，还在上升） |
| Kodak PSNR（名义 / 功率修正） | 28.80 / 28.80 dB |
| 实际发射功率 | 验证集 0.99，Kodak 0.98，满足约束 |
| 星座熵 | 6.00 bit，64 个点几乎均匀使用 |

- **学习率没有衰减**：验证 loss 每轮都在改善，平台期衰减一次都没触发。
- **σ_q 只涨到 15**：按参数更新计步、批大小 32 时，200 轮只有约 2.2 万次更新。"只加 KL"组按小批次计步，σ_q 已到 45。
- **对比先不下结论**：两组的学习率和更新次数差很多，对比会受训练设置干扰。等 KL 组出完 Kodak 结果，我再把两组连同旧基线整理成表给你。

<details><summary>工具调用 × 1</summary>

- `Bash` Collect final results for both groups

</details>

**助手：**

两组 200 轮都跑完了：跑满 200 轮时"只加 KL"组略高，但按同样的参数更新次数算，"全改"组明显更好。两组都还没收敛，现在还定不了最终方案。

## 结果

| 指标 | 旧设置 + KL | 论文全改 |
|---|---|---|
| 验证集 PSNR（功率修正后） | **27.95 dB**（第 200 轮最好） | 27.70 dB（第 198 轮最好） |
| Kodak PSNR（功率修正后） | **29.11 dB** | 28.80 dB |
| 实际发射功率 | 1.00 | 0.98–0.99 |
| 星座熵 | 6.00 bit | 6.00 bit |
| 每轮耗时（单独运行时） | 约 14–16 秒 | 约 12.6 秒 |
| 200 轮内的参数更新次数 | 43,200 | 21,600 |
| 结束时的 σ_q | 45 | 15 |

- **两组功率都已达标**：加了 KL 之后，两组功率都在 1 附近，所以名义 PSNR 和修正后的 PSNR 基本一样，结果可以直接公平比较。
- **加 KL 本身不亏**：旧主线第 200 轮是 27.65 dB，但那是功率 1.22 下的名义值，修正后大约 27.35 dB。只加 KL 那组是 27.95 dB，同样训练量下反而高约 0.6 dB。这个差距没有剔除随机种子的影响，只能作参考。

## 按参数更新次数对齐

| 更新次数 | 旧设置 + KL | 论文全改 | 差值 |
|---|---|---|---|
| 10,800 次 | 25.26 dB（第 50 轮） | 26.15 dB（第 100 轮） | +0.9 dB |
| 21,600 次 | 26.32 dB（第 100 轮） | 27.70 dB（第 200 轮） | +1.4 dB |

全改组的学习率只有一半，σ_q 也涨得慢，但每次参数更新带来的提升明显更多。它在 200 轮时落后，主要是因为批大小 32 让每轮的更新次数少了一半，不能说明新结构更差。

## 这个实验说明不了什么

全改组同时改了结构、批大小、学习率和 σ_q 的计步方式，所以区分不出"结构改动本身"值多少 dB。另外两组都还在上升：全改组的学习率一次都没衰减，σ_q 离 100 还很远。所以 200 轮的结果只能看趋势，不能当最终性能。

## 建议的下一步（二选一）

1. **补一组隔离实验，约 50 分钟**：论文结构 + 旧训练设置（批大小 8、有效批大小 16、学习率 2e-4、σ_q 按小批次计步），跑 200 轮，和"只加 KL"组直接对比，单独看结构改动的收益。
2. **直接用全改配置做长训练**：1200 轮约 4.2 小时。要注意按参数更新计步时，σ_q 到第 1200 轮也只能涨到约 65。如果希望它像论文那样涨到 100，可以把"每 1 万次更新加 5"按我们的数据规模缩短步长，但这会偏离论文原文，需要你决定。

我倾向先做方案 1，确认结构改动值得，再开长训练。你看怎么安排？

### 用户 · 2026-09-28 04:42

> 先做方案1，跑隔离实验

<details><summary>工具调用 × 2</summary>

- `Bash` Run group C: paper arch with legacy training settings
- `Bash` Confirm group C started correctly

</details>

**助手：**

隔离实验已经启动，只有这一组在跑。

- **目录**：`runs/cmp200_paper_arch_legacy_train`
- **配置**：论文结构 + KL，训练设置和"只加 KL"组完全相同：批大小 8、有效批大小 16、学习率 2e-4、σ_q 按小批次计步。两组唯一的区别就是网络结构。
- **速度**：每轮约 16 秒，200 轮约 55 分钟。

早期苗头不错：第 3 轮验证集 21.13 dB，"只加 KL"组同一轮是 20.14 dB，领先约 1 dB。不过前期领先不一定能保持到最后，要等跑完再看。

跑完后我会把三组和旧基线放在一张表里，按相同轮数对比。

<details><summary>工具调用 × 2</summary>

- `Bash` Collect three-group comparison table
- `Bash` Find epoch where old run matched new result

</details>

**助手：**

论文结构本身明显有效：训练设置完全相同时，200 轮后结构改动带来约 **+1.5 dB**。上一轮"全改"组表现差，原因在论文的训练设置（批大小 32、学习率 1e-4），不在结构。

## 结果（验证集 PSNR，功率修正后，单位 dB）

| 轮数 | 旧基线（无 KL，名义值） | 旧结构 + KL | **论文结构 + KL + 旧训练设置** | 论文全改 |
|---|---|---|---|---|
| 3 | 20.32 | 20.14 | **21.13** | 19.69 |
| 25 | 24.39 | 23.88 | **25.38** | 23.82 |
| 50 | 25.47 | 25.26 | **26.85** | 24.95 |
| 100 | 26.73 | 26.32 | **28.51** | 26.15 |
| 150 | 27.14 | 27.07 | **29.08** | 27.10 |
| 200 | 27.65 | 27.95 | **29.49** | 27.70 |
| Kodak（第 200 轮） | — | 29.11 | **30.68** | 28.80 |

旧基线一栏是名义值：发射功率是 1.22，修正后要低约 0.3 dB，其他三组都已修正。三组的发射功率都在 0.99 到 1.00 之间，星座熵都是 6.00 bit。

## 结论

1. **结构改动值得做**：同样的训练设置，论文结构领先 1.5 到 2.2 dB，而且领先从第 3 轮一直保持到第 200 轮，不是偶然波动。参数量完全相同（38.7 万），FPGA 只多了几个加法和 ReLU。
2. **收敛快了两倍多**：新配置 200 轮就到 29.49 dB，旧主线要到第 461 轮才到这个值，按功率修正后对齐要到第 546 轮。
3. **论文的训练设置不适合我们的规模**：批大小 32 加学习率 1e-4，在每轮只有 3450 张图的数据量下更新次数太少，200 轮落后约 1.8 dB。论文用的是 ImageNet，一轮就有上万次更新，两者的情况不一样。
4. **KL 项该保留**：它让功率满足约束，同样训练量下也没有损失精度。

## 建议的下一步

用"论文结构 + KL + 旧训练设置"做长训练：1200 轮，每轮约 15.7 秒，大约 5.2 小时。可以直接从这次第 200 轮的模型续训，省掉约 50 分钟。

有两个细节需要你定：
- **学习率要不要后期衰减**：旧训练设置里学习率一直不变。可以在后期加平台期衰减（loss 连续若干轮不降就把学习率乘 0.8），通常能在收尾时多挤出一点精度。我建议加，并把"连续多少轮不降"放宽到 20 轮，适配我们这种小 epoch。
- **σ_q 怎么计步**：这组按小批次计步，1200 轮约 51.8 万步，σ_q 大约在第 440 轮到 100 封顶，和旧主线行为一致。我建议保持不变。

要按这个方案开始长训练吗？

### 用户 · 2026-09-28 07:45

> 好的，按这个方案进行长训练

**助手：**

先改训练脚本：平台期衰减的"连续多少轮不降"改成可配置，并让续训时重新设随机种子，避免数据顺序重复前面的轮次。

<details><summary>工具调用 × 3</summary>

- `Bash` Add plateau patience option; set up long-run dir
- `Bash` Long training: paper arch, resume from epoch 200 to 1200
- `Bash` Confirm resume works and CSV continues

</details>

**助手：**

长训练已经启动，从隔离实验第 200 轮的模型接着往下跑，续训确认正常。

- **目录**：`runs/long1200_paper_arch`。前 200 轮的日志和参数另存为 `stdout_epoch1-200.log` 和 `args_epoch1-200.json`，`training.csv` 从第 201 轮接着写。
- **配置**：论文结构 + KL（λ=0.05），批大小 8，有效批大小 16，学习率 2e-4。平台期衰减：连续 20 轮不降就把学习率乘 0.8。σ_q 按小批次计步。
- **接续情况**：参数更新次数（43,416）和 σ_q（45）都和第 200 轮连上了。第 201 到 203 轮验证集在 29.3 到 29.4 dB，和续训前的 29.48 dB 在同一水平，波动正常。
- **进度**：每轮约 17 秒，剩下 1000 轮大约 4.8 小时。

我对 `train_v2.py` 做了两处小改动：
- 平台期衰减的轮数改成了可配置参数 `--plateau-patience`，默认仍是论文的 4。
- 续训时会重新设随机种子，避免数据顺序重复前面的轮次。

跑完后脚本会自动在 Kodak 上评估，我收到完成通知后把结果整理给你。

### 用户 · 2026-09-28 08:36

> 目前进度如何

<details><summary>工具调用 × 2</summary>

- `Bash` Check long training progress
- `Bash` Compare with old run at same epoch

</details>

**助手：**

训练正常，没有报错，目前跑到第 374/1200 轮。

- **当前精度**：验证集最好是 **30.29 dB**，出现在第 368 轮，数值已按实际功率修正。发射功率 1.00，星座熵 6.00 bit，都正常。
- **和旧主线比**：旧主线到第 374 轮时最好是 29.26 dB，而且那是功率 1.22 下的名义值，修正后还要低约 0.3 dB，所以新模型同轮次领先 1 dB 以上。旧主线要到第 744 轮才达到 30.29 dB。
- **σ_q**：已涨到 85，大约第 440 轮封顶在 100。
- **学习率**：已经触发过一次平台期衰减，从 2e-4 降到 1.6e-4。
- **剩余时间**：平均每轮 17.3 秒，剩下 826 轮大约还要 4 小时，预计今晚 21:40 左右结束。

跑完后脚本会自动在 Kodak 上评估，我收到完成通知后把最终结果整理给你。

### 用户 · 2026-09-28 09:41

> 可以的。最终这个网络我需要部署到FPGA上，有个问题是物理层波形使用OFDM，和802.11a的帧结构类似，因此PAPR是个问题。你有什么解决思路吗

**助手：**

我的思路是：把"压低 PAPR"换成"允许削波、让网络学会容忍失真"。DeepJSCC-Q 的接收端直接吃连续 I/Q，没有硬判决，这正是它相对传统数字系统的优势。

## 一个关键判断：PAPR 在我们这里是"失真"，不是"误码"

传统 802.11a 怕 PAPR：削波失真会让 LDPC 解码跌下悬崖，所以只能靠大回退来避免。我们的情况不同：
- 解码器看到的是连续样本，削波失真对它来说只是另一种噪声，性能会平滑下降，不会断崖。
- 削波后峰值变小，在同样的 PA 峰值约束下可以把平均功率抬高，相当于提高了 SNR。

所以真正该优化的不是 PAPR 本身，而是**在 PA 峰值功率受限时的端到端 PSNR**。削得狠一点，失真变大，但 SNR 也跟着变高，中间存在一个最优削波门限。这条路 FPGA 实现也最便宜。

## 建议的路线（由简到繁）

**第 1 步：可逆扰码加交织（必做，零损失）**

我们的 latent 是按"通道、行、列"顺序两两配成 I/Q 的，相邻符号来自相邻像素，相关性很强。直接映射到相邻子载波，同相叠加会让 PAPR 比随机数据更差。可以做两件事：
- 用伪随机置换打散符号到子载波的映射。
- 每个符号乘上伪随机的 {1, j, −1, −j}。**64-QAM 旋转 90° 后仍然落在原星座点上**，发射的还是合法点。接收端对连续 y 做反旋转是精确可逆的，而复高斯噪声旋转后统计特性不变，所以对 PSNR 没有任何损失。

FPGA 上只需要一张地址表加上符号取反、I/Q 互换，几乎不占资源。做完之后，每个 OFDM 符号的 PAPR 分布应该接近随机 64-QAM 的理论值，52 个子载波时约 10–11 dB（CCDF 取 1e-3）。

**第 2 步：削波加滤波（主力手段）**

- 在 4 倍过采样的时域信号上按幅度削波：超过门限 A 的样本缩放到 A，相位保持不变。
- 削波会产生带外频谱，再做一次频域滤波（FFT，把带外置零，再 IFFT），也可以用时域 FIR 代替，这样频谱模板就能保证。
- 剩下的带内失真交给解码器去扛。

FPGA 上每个样本需要一次比较和一次缩放（倒数平方根可以用 CORDIC 或查表），再加一对 256 点 FFT/IFFT 或一个 FIR，ZU5EG 完全能承受。

**第 3 步：把削波放进训练回路微调（关键增益来源）**

IFFT、削波、滤波都可以在 PyTorch 里写成可微的形式（`torch.fft`，削波用直通梯度或者软削波），接进 AWGN 前面。有两种微调方式：
- 只微调解码器：发射端不动，风险小。
- 端到端微调：编码器也可能学会避开造成大峰值的符号组合，但符号被扰码打散后，这种能力有限。

交接文档里做过一个很小的测试：12 位 DAC 加 4 倍平均幅度削波，PSNR 变化只有 ±0.02 dB。这说明削波在我们的链路里很可能很便宜，但样本太少，需要系统地重测一遍。

**不建议走的路**

- SLM/PTS：需要多路 IFFT 加边信息，边信息一旦出错整个符号就废了。
- 预留子载波（tone reservation）：占用传输资源。交接文档里已经试过，增益没达到你定的 3 dB 门槛。
- 让编码器学习压低 PAPR：同样试过，效果不明显。

这几条都属于你之前定的"额外收益不到 3 dB 就放弃"的复杂路线。

## 评估方法

我建议统一用"PSNR 对 PA 回退量"或"PSNR 对峰值归一化 SNR"的曲线来评价，而不是只看 PAPR 的 CCDF。可以分三步测：

1. 用长训练的模型测三组 PAPR 的 CCDF：实际 DeepJSCC-Q 符号不加扰码、加扰码、随机 64-QAM，验证相关性问题到底有多大。
2. 固定峰值功率，削波门限从 3 dB 扫到 9 dB，画 PSNR 曲线，先不重训，找出最优门限。
3. 在最优门限附近把削波放进训练回路微调，看能挽回多少。

第 1、2 步不占多少 GPU，可以现在就用长训练的当前模型开始做。第 3 步等长训练结束再跑。

## 需要你提供的信息

1. **射频前端的实际限制是什么？** PA 允许的回退量，有没有 DPD，DAC 位数和型号（比如是不是 AD9361 这类），以及有没有频谱模板或 ACLR/EVM 指标要满足。这决定了削波门限的约束和评估标准。
2. **帧结构细节**：是否沿用 64 点 FFT、48 个数据子载波、4 个导频、16 点 CP？前导码可以直接用 802.11a 的短训练序列和长训练序列（STF/LTF），它们本身的 PAPR 就低，不用处理。
3. **信道模型**：先只做 AWGN，还是要把多径和频偏也放进仿真？

要我现在先开始第 1、2 步的测量吗？

### 用户 · 2026-09-28 09:46

> 1.射频前端就是AD9361，没有频谱模板；2.是的，64 点 FFT、48 个数据子载波、4 个导频、16 点 CP；3.实际上多径和频偏都可均衡掉，我认为这些不需要仿真。唯一问题就是均衡后各个子载波的SNR不一致，这和我们训练使用的AWGN不太一致，我觉得最后的信道模型可以试一试非高斯噪声

**助手：**

信息够用了。先说判断，然后我就开始搭仿真。

## 对三点信息的判断

**1. AD9361、没有频谱模板**
- 削波后可以不做滤波。接收端的 64 点 FFT 只看带内，削波和"削波加一次滤波"在带内的效果完全相同；带外的频谱再生本来就会被 AD9361 发射通路里的 FIR 和模拟低通滤掉一部分。
- 这样约束就只剩 DAC 满量程和发射功率的峰值限制：削得越狠，平均功率越高，等效 SNR 越高，但带内失真也越大。所以要找一个最优削波比。
- 还需要你确认一点：AD9361 后面有没有外接 PA？如果没有，只考虑 DAC 峰值就够了；如果有，可能还要加一个 PA 非线性模型。

**2. 帧结构**：我直接按 802.11a 的子载波位置搭。
- 数据子载波是 ±1 到 ±26，去掉 ±7 和 ±21；导频放在 ±7、±21，极性序列用标准的 x⁷+x⁴+1 生成；CP 为 16 点。
- 一张 256×256 的图有 32768 个符号，正好是 683 个 OFDM 符号，最后一个补零。

**3. 各子载波 SNR 不一致**：这个判断对，而且可以精确建模，不需要真去仿真多径波形。
- CP 覆盖时延扩展时，均衡后第 k 个子载波上是 y_k = x_k + n_k/H_k。噪声对每个子载波仍是高斯的，只是方差按 1/|H_k|² 变化。对整幅图来看，就是一个**高斯尺度混合**，重尾、非高斯，也就是你说的非高斯噪声。
- 最贴近实际的造法：用指数功率时延谱的瑞利多径随机生成 H_k。这样相邻子载波的相关性、深衰落的比例都自然带出来，比凭空假设一个重尾分布更可信。
- 均衡方式影响很大：
  - ZF（直接除以 H_k）在深衰落上会把噪声放大到无穷，最坏的子载波会主导失真。
  - MMSE，即 H*y/(|H|²+σ²)，会自动把不可靠的子载波往 0 压，相当于隐式告诉解码器"这个值别信"。而且解码器不需要额外输入，符合最终版论文"解码器只看 y"的要求。
  
  我预计 MMSE 会明显更好，两种都要测。
- 可逆扰码加交织在这里又多了一个作用：频率选择性衰落在一帧内通常是固定的，差的子载波每个符号都差；打散以后，这些差符号会分散到整幅图的 latent 里，不会集中毁掉某一块。
- 信道估计误差也顺便建进来：两个 LTF 平均后，估计噪声的方差是 σ²/2。

## 马上要做的测量（不重训）

用长训练当前最好的模型测：
1. **PAPR 的 CCDF**：分三种情况，实际 DeepJSCC-Q 符号不扰码、加扰码、随机 64-QAM，看相关性到底让 PAPR 恶化了多少。
2. **只有 AWGN 时扫削波比**：固定峰值功率，让不削波时的 SNR 为 10 dB，削波比从 12 dB 扫到 3 dB，画 PSNR 曲线，找最优点。
3. **频率选择性信道**：均方根时延扩展分几档，比较 ZF 和 MMSE，看不重训时 PSNR 掉多少，作为后面把这个信道放进训练回路微调的基线。

这些测量都是推理，对正在跑的长训练影响很小。先写 OFDM 信道模块：

<details><summary>工具调用 × 1</summary>

- `Write` <work>\DeepJSCC-Q\ofdm_channel.py

</details>

**助手：**

Now the evaluation script. First a sanity check: with no clipping and a flat channel, the OFDM link should give the same PSNR as the AWGN channel.

<details><summary>工具调用 × 4</summary>

- `Bash` Write OFDM eval script and run sanity and PAPR checks
- `Bash` Use ZF for flat channel; run clip and fading sweeps
- `Write` ~\.claude\projects\D--ClaudePrj-DeepJSCC-Q\memory\deployment-phy-constraints.md
- `Bash` Add memory index entry

</details>

**助手：**

OFDM 链路模型已经搭好，三项测量都做完了，都没有重训。结论是：PAPR 用扰码加削波就能解决；真正的难点是频率选择性信道，不重训要掉 3 到 5 dB。

测试用的是长训练第 368 轮附近的模型，对应代码是 [ofdm_channel.py](ofdm_channel.py) 和 [ofdm_eval.py](ofdm_eval.py)，结果在 `runs/ofdm_eval/`。

**完整性检查**：平坦信道、不削波、ZF 均衡时，OFDM 链路的 PSNR 是 30.861 dB，AWGN 是 30.861 dB，完全一致，说明整条链路模型是对的。

## 1. PAPR：扰码是必需的，而且已经够好

| 情况 | CCDF 1e-2 | 1e-3 | 1e-4 |
|---|---|---|---|
| 模型符号，不扰码 | 15.2 dB | 16.2 dB | 16.6 dB |
| 模型符号，加扰码和交织 | 9.6 dB | **10.5 dB** | 11.1 dB |
| 随机 64-QAM | 9.6 dB | 10.5 dB | 11.2 dB |

- 相邻 latent 高度相关，不扰码时 PAPR 比随机数据差了约 **5.7 dB**。
- 加扰码后和随机 64-QAM 完全重合，符号已被完全白化，编码器没有留下可以再利用的结构。
- 所以再往 PAPR 本身上加复杂方法，增益上限就是随机 OFDM 的理论值，不值得。

## 2. 削波：几乎白送的 SNR

先看 SNR 固定为 10 dB 时削波造成的纯失真损失：

| 削波比 | 7 dB | 6 dB | 5 dB | 4 dB | 3 dB |
|---|---|---|---|---|---|
| PSNR 损失 | 0.01 | 0.05 | 0.12 | 0.26 | 0.49 |

再看峰值功率受限（DAC 满量程固定）时的情况：以不削波时 SNR 为 10 dB 为基准，削得越狠，平均功率越高：

| 削波比 | 不削 | 8 dB | 6 dB | **5 dB** | 4 dB | 3 dB |
|---|---|---|---|---|---|---|
| 等效 SNR | 10 dB | 14 dB | 16 dB | **17 dB** | 18 dB | 19 dB |
| PSNR | 30.86 | 31.82 | 32.05 | **32.09** | 32.08 | 31.97 |

- **最优削波比约为 5 dB，不重训就能多出 +1.2 dB**。
- 这是 DeepJSCC 的平滑退化特性带来的，传统系统做不到。
- FPGA 上只需要每个样本做一次幅度比较和一次缩放。没有频谱模板，削波后不用滤波。
- 把削波放进训练回路之后，最优点可能还能再往低推。

## 3. 频率选择性信道：真正的难点

条件：平均 SNR 为 10 dB，瑞利多径，信道在一帧内不变，时延扩展按采样点计（20 MHz 采样时 1 个采样点等于 50 ns）。AWGN 基准是 30.86 dB。

| 时延扩展 | ZF + 理想 CSI | ZF + LTF 估计 | MMSE + 理想 CSI | MMSE + LTF 估计 |
|---|---|---|---|---|
| 0.5 个采样点 | 24.78 | 21.97 | 25.92 | 23.65 |
| 1 个采样点 | 25.08 | 23.21 | 26.92 | 25.20 |
| 2 个采样点 | 25.37 | 23.85 | 27.28 | 25.94 |
| 4 个采样点 | 25.61 | 23.93 | **27.61** | 26.15 |

- **不重训时损失 3 到 5 dB**。其中一部分是衰落信道固有的：同样的平均 SNR 下，衰落信道本来就比 AWGN 差，这部分无法全部挽回。
- **MMSE 比 ZF 好 1.1 到 2.0 dB**。它自动压低不可靠的子载波，解码器不需要额外输入，符合论文"解码器只看 y"的要求。应该用 MMSE。
- **信道估计误差再损失 1.4 到 2.3 dB**，这部分可以低成本挽回（见下面第 3 步）。
- 时延扩展越大反而越好：扰码把符号打散到各子载波，频率分集起了作用。时延扩展接近 0 时相当于整帧平坦衰落，最差。

## 建议的方案

1. **发射端**：可逆扰码加交织（已实现，零损失），再削波到约 5 dB。PAPR 问题到此基本解决，不需要预留子载波、SLM 这类复杂方案。
2. **接收端均衡**：用 MMSE。
3. **信道估计去噪**：对 LTF 的最小二乘估计做一次 64 点 IFFT，只保留 CP 长度内的 16 个抽头，再 FFT 回去。估计噪声理论上能降约 6 dB，只多一对 64 点 FFT。我可以先在仿真里验证。
4. **信道放进训练回路微调**：这就是你说的非高斯噪声。训练时每张图随机抽一个信道：时延扩展从平坦到 4 个采样点不等，加上 5 dB 削波、LTF 估计误差和 MMSE 均衡，让解码器学会衰落和削波带来的失真。等长训练结束（约 21:40）后，从长训练的最好模型开始微调，编码器和解码器一起调。

还有两个信息需要你确认：
- AD9361 后面有没有外接 PA？
- 实际采样率是不是 20 MHz？这决定了时延扩展换算成多少个采样点。

要我现在先做第 3 步的信道估计去噪仿真吗？它只做推理，不影响正在跑的长训练。

### 用户 · 2026-09-28 09:52

> 没有外接PA，采样率20MHz，先做信道估计去噪仿真

**助手：**

先把这两个信息记下来，然后实现 DFT 域的信道估计去噪。

要注意一点：802.11a 的 LTF 只激励 52 个子载波，直流和保护子载波上没有观测，所以不能直接对 64 个点做 IFFT 后截断，那样会产生泄漏。正确做法是用最小二乘把 52 个观测值拟合成 L 抽头的时域信道，再变换回全部子载波。这等价于乘一个预先算好的 64×52 固定复矩阵，FPGA 上每帧只做一次，开销很小。

<details><summary>工具调用 × 3</summary>

- `Bash` Update PHY memory with PA and sample rate
- `Read` <work>\DeepJSCC-Q\ofdm_channel.py
- `Bash` Add DFT-domain channel estimation and evaluate it

</details>

**助手：**

信道估计去噪很有效：保留 16 个抽头（等于 CP 长度）时，估计误差降了 5.1 dB，不完美 CSI 造成的 PSNR 损失从 1.4 到 2.3 dB 缩小到 0.2 到 0.8 dB。

条件：MMSE 均衡，平均 SNR 10 dB，瑞利多径，时延扩展按采样点计（20 MHz 时 1 个采样点等于 50 ns）。结果在 `runs/ofdm_eval/chest.json`。

## 结果（PSNR，dB）

| 时延扩展 | 理想 CSI | LTF 直接估计 | **DFT 去噪，16 抽头** | DFT 去噪，12 抽头 | DFT 去噪，8 抽头 |
|---|---|---|---|---|---|
| 0.5 个点（25 ns） | 25.92 | 23.65 | **25.12** | 25.33 | 25.53 |
| 1 个点（50 ns） | 26.92 | 25.20 | **26.49** | 26.66 | 26.82 |
| 2 个点（100 ns） | 27.28 | 25.94 | **27.09** | 27.21 | 26.89 |
| 4 个点（200 ns） | 27.61 | 26.15 | **27.26** | 26.66 | 24.38 |
| 估计误差 | — | −13.0 dB | **−18.1 dB** | −19.4 到 −14.5 dB | −21.1 到 −9.6 dB |

- **16 抽头去噪**：估计误差从 −13.0 dB 降到 −18.1 dB，改善 5.1 dB，正好是 10·log10(52/16)，和理论一致。和理想 CSI 相比的 PSNR 差距缩小到 0.2 到 0.8 dB。
- **8 或 12 抽头**：时延扩展小的时候稍好一点，但 4 个采样点时模型失配，8 抽头会掉到 24.38 dB，比不去噪还差。
- **选 16 抽头**：它等于 CP 长度。超过 CP 的信道 OFDM 本身就会失效，所以 16 抽头对所有 OFDM 能正常工作的信道都成立。没必要按信道自适应选抽头数，不划算。

## FPGA 实现

每帧只做一次：用 52 个 LTF 最小二乘估计值乘一个预先算好的固定复矩阵。实际只需要数据和导频对应的 52 行，也就是 52×52 次复数乘加。这个开销对 ZU5EG 可以忽略。矩阵系数的定点位宽后面做定点化时再确认。

## 目前的接收端方案

均衡后的 I/Q 送进解码器之前依次经过：LTF 最小二乘估计，16 抽头 DFT 去噪，MMSE 均衡，最后解扰。发射端是扰码加交织，再削波到 5 dB。

## 下一步

剩下的差距主要是衰落本身带来的：在瑞利信道下，AWGN 的 30.86 dB 降到了 25 到 27 dB。要挽回，就得把整条 OFDM 链路放进训练回路微调，也就是你说的非高斯噪声训练。具体设置：
- 每张图随机抽一个信道，时延扩展在 0 到 4 个采样点之间，包括平坦衰落；
- 5 dB 削波；
- LTF 估计加 16 抽头 DFT 去噪；
- MMSE 均衡；
- 平均 SNR 10 dB。

长训练预计 21:40 左右结束。我可以现在先把这套信道接进 `train_v2.py`，只写代码、做短时冒烟测试，不影响长训练；等长训练一结束，就从它的最好模型开始微调。要这样安排吗？

### 用户 · 2026-09-28 10:02

> 先不要，LS复杂度实在太高。你最好找找商用的wifi芯片是怎么做的，或者找开源的代码，比如openwifi，是怎么处理信道估计和均衡的

<details><summary>工具调用 × 2</summary>

- `WebFetch` https://raw.githubusercontent.com/jhshi/openofdm/master/docs/source/eq.rst
- `WebFetch` https://github.com/open-sdr/openofdm/tree/master/verilog

</details>

**助手：**

Now the Verilog for open-sdr/openofdm, the receiver used by openwifi, to check what the equalizer actually does:

<details><summary>工具调用 × 2</summary>

- `Bash` Download openofdm equalizer.v from both repos
- `Bash` Read open-sdr state machine; check jhshi smoothing

</details>

**助手：**

jhshi/openofdm 的 master 分支有频域滑动平均平滑，open-sdr 的 master 分支没有。接着查 openwifi 实际用的是哪个分支，以及平滑的具体做法：

<details><summary>工具调用 × 7</summary>

- `Bash` Find openofdm branch used by openwifi-hw
- `Bash` Query GitHub API for branches and submodule SHA
- `Bash` Fetch equalizer.v at the openwifi-hw submodule commit
- `Bash` Read openwifi channel smoothing and CPE logic
- `Bash` Add openwifi-style moving-average smoothing and compare
- `Bash` Check openwifi SFO slope tracking and noise variance use
- `Bash` Read openwifi per-subcarrier phase correction

</details>

**助手：**

我查了 openwifi 实际使用的接收端代码，并按它的做法重新仿真。结论是：照搬 openwifi 的"LS 加 3 点平滑"，再把 ZF 换成 MMSE，效果和我之前那个高复杂度的 DFT 拟合基本一样，硬件开销却比 openwifi 本身还小。

## openwifi 是怎么做的

我看的是 openwifi-hw 子模块锁定版本（提交 `2bb3ad1`）的 `equalizer.v`：

1. **LS 估计**：两个 LTS 按已知 ±1 符号取反后平均，每帧只做一次。
2. **频域平滑**：沿子载波方向做 **3 点滑动平均**，边缘子载波用更短的窗口，可以用开关关掉。
3. **噪声方差**：用两个 LTS 的差值顺便估出来。
4. **均衡**：ZF，每个数据样本算一次 y·conj(H)/|H|²，**每个样本都走一次除法器 IP**。
5. **相位跟踪**：每个 OFDM 符号用 4 个导频估计**公共相位误差（CPE）**，所有子载波统一旋转补偿。**没有采样频偏（SFO）引起的相位斜率补偿。**

商用芯片的具体实现拿不到。据我所知，业界普遍也是"LS 加频域平滑"这一套，基本不会用最小二乘拟合。802.11n 的 HT-SIG 里专门有一个 Smoothing 位，就是为了告诉接收机能不能跨子载波平滑信道估计（做了波束赋形时不能平滑）。

## 仿真对比

条件：平均 SNR 10 dB，瑞利多径，20 MHz 采样时 1 个采样点等于 50 ns。

| 时延扩展 | 均衡 | 理想 CSI | 纯 LS | **LS + 3 点平滑（openwifi）** | LS + 5 点平滑 | DFT 拟合（已放弃） |
|---|---|---|---|---|---|---|
| 25 ns | ZF | 24.78 | 21.97 | 23.50 | 23.93 | 23.57 |
| | **MMSE** | 25.92 | 23.65 | **25.05** | 25.37 | 25.12 |
| 50 ns | ZF | 25.08 | 23.21 | 24.56 | 24.88 | 24.69 |
| | **MMSE** | 26.92 | 25.20 | **26.44** | 26.66 | 26.49 |
| 100 ns | ZF | 25.37 | 23.85 | 25.12 | 24.93 | 25.22 |
| | **MMSE** | 27.28 | 25.94 | **26.98** | 26.80 | 27.09 |
| 200 ns | ZF | 25.61 | 23.93 | 24.52 | 22.76 | 25.16 |
| | **MMSE** | 27.61 | 26.15 | **26.77** | 24.98 | 27.26 |

- **3 点平滑**：
  - 时延扩展 ≤ 100 ns 时，和 DFT 拟合只差 0 到 0.1 dB，比纯 LS 好 1.0 到 1.4 dB。
  - 200 ns 时比 DFT 拟合低 0.5 dB，但仍比纯 LS 高 0.6 dB。
  - 室内典型的均方根时延扩展大约 30 到 100 ns，所以 3 点平滑够用。
- **5 点平滑**：小时延扩展时略好，到 200 ns 就会比纯 LS 还差，不稳健。
- **MMSE 比 ZF 稳定高 1.1 到 2.2 dB**，这是整条接收链里最划算的改动。

## 复杂度对比

| 环节 | openwifi | 建议方案 |
|---|---|---|
| LS 估计（每帧） | 52 次加法和取反 | 相同 |
| 3 点平滑（每帧） | 用除法器除以 3 | 每个子载波 2 次加法，再乘一个常数 1/3 |
| 均衡权重（每帧） | 无 | 52 个子载波各算一次 1/(\|H\|²+σ²)，σ² 用 LTS 差值估计，openwifi 本来就算了 |
| **均衡（每个样本）** | **1 次复乘 + 2 路除法** | **1 次复乘 + 1 次实数缩放**，不需要除法器 |

建议方案每个样本的开销比 openwifi 还小，因为除法从每个样本一次挪到了每帧 52 次。MMSE 相对 ZF 只多了每帧 52 次加法。

## 必须提醒的一点：采样频偏

openwifi 只补偿 CPE，是因为 Wi-Fi 的包很短，一般只有几十到一百多个 OFDM 符号。我们一帧图像有 **683 个 OFDM 符号，约 2.7 ms**。

两块板各用一个 AD9361、各自一个晶振，假设相对频偏 10 ppm：到帧尾时，边缘子载波（±26）会累积约 **80°** 的相位斜率，CPE 补偿修不掉这部分。你说"频偏可以均衡掉"，如果指的是载波频偏（CFO），那采样频偏（SFO）要另外处理。有两种办法：

1. **导频估计相位斜率**：每个符号用 ±7、±21 这 4 个导频拟合线性相位，按子载波序号补偿。每个符号只需要几次乘加，加一张旋转查找表或 CORDIC。
2. **共用参考时钟**：只适合实验室联调，实际部署做不到。

我还没把 SFO 放进仿真。如果需要，可以加进去，看残余斜率会对 PSNR 造成多少损失。

## 建议的接收端方案

两个 LTS 的 LS 估计 → 3 点频域平滑 → 用 LTS 差值估噪声方差 → MMSE 均衡（每帧先算好权重，每个样本只做乘法） → 导频 CPE 加 SFO 斜率跟踪 → 解扰 → 解码器。

发射端不变：扰码加交织，削波到约 5 dB。

我这边的改动：把 openwifi 式平滑加进了 [ofdm_channel.py](ofdm_channel.py)，参数是 `csi='ltf_ma'`。DFT 拟合的代码暂时保留，只作对照。结果在 `runs/ofdm_eval/chest_ma.json`。长训练还在后台跑，不受影响。

你看这个接收端方案可以吗？确定之后，等长训练结束，就按这套信道（3 点平滑加 MMSE）做微调。

### 用户 · 2026-09-28 10:29

> 看这个，这是我现在使用的接收机算法，我的RTL也是几乎按照这个写好的："D:\MATLABPrj\PHY_80211a.m"，唯一区别就是没做平滑，因为我要接收更长的帧，我的首要目的是保证对SFO的容忍，因此FFT窗口是有回退的，这种情况下去做平滑需要先补偿相位，然后平滑，然后再乘回去，过于繁琐（不太清楚openwifi这部分是怎么做的，可能他们没考虑长帧，因为你也说了他们没有补偿SFO。另外我不太清楚你使用到的多径信道模型是什么，不过考虑一下wifi的场景，不太可能存在很大的时延扩展。综合考虑一下，给我最小的改动方案。

<details><summary>工具调用 × 4</summary>

- `Bash` Check the MATLAB receiver file size
- `Read` D:\MATLABPrj\PHY_80211a.m
- `Bash` Add user PDP, single-LTS CSI, I/Q clipping, MMSE post-scale
- `Bash` Add user PDP, single-LTS CSI, I/Q clipping, MMSE post-scale

</details>

**助手：**

The Bash permission check is temporarily failing, so I'll make the changes with the file editor instead:

<details><summary>工具调用 × 5</summary>

- `Read` <work>\DeepJSCC-Q\ofdm_channel.py
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py

</details>

**助手：**

这次的仿真改动还没写进去：权限检查服务连续几次没有返回结果，文件编辑和命令都执行不了。所以下面的结论是基于你的代码和前面数据的分析，削波门限等数字需要仿真确认。

## 先说你的信道

你用的 TGn 风格 5 径（时延 0 到 40 ns，功率 0 到 −27.7 dB），按功率加权算出的均方根时延扩展只有约 **4.3 ns**，而 20 MHz 的采样间隔是 50 ns。所以 52 个子载波上的信道几乎一样，基本是**平坦瑞利衰落**，而且一帧内静止。

我前面用的是按采样点间隔的指数衰减多径，均方根时延扩展 25 到 200 ns，比你的场景频率选择性强得多。那组"MMSE 比 ZF 好 1 到 2 dB"、"平滑能挽回 1 dB"的结论，是在强频率选择性下得出的，不能直接套用。在你的场景下：
- 各子载波的 SNR 差别很小。真正变化的是**每帧整体的 SNR**：有的帧整帧落入深衰落。这对应最终版论文里的慢衰落场景（论文 Fig. 9）。
- 频域平滑的主要作用变成降低估计噪声。你不做平滑可以接受，用下面第 3 条的双 LTS 平均来弥补。

## 最小改动方案

**发射端**

1. **把比特级的扰码、卷积编码、交织换成符号级的扰码加交织（必须做）**
   - 做法：对 latent 符号做一个固定的伪随机置换，再乘上伪随机的 {1, j, −1, −j}，这样 64-QAM 仍然落在原星座点上。硬件上只是一张地址表，加上取反和 I/Q 互换。
   - 作用：前面实测过，不扰码时 PAPR 在 CCDF 1e-3 处是 16.2 dB，扰码后降到 10.5 dB，和随机 64-QAM 一样。同时它把深衰落的影响打散到整幅图上。
2. **I/Q 削波保留你现有的 `min(max(x,-2),2)`，只改门限常数**
   - I/Q 分别饱和正好对应 AD9361 两路 DAC 各自的满量程，结构不用改。
   - 你现在的数据段平均功率是 52/64，每一路的 RMS 约为 0.64，门限 ±2 大约是 RMS 的 3.1 倍（高出 9.9 dB），基本不起削波作用。
   - 前面按幅度削波仿真，最优点在比 RMS 高约 5 dB 处。换成 I/Q 分别削波、不过采样之后，最优门限要重新仿真确定，我估计在 ±1.1 到 ±1.3 之间。
   - AD9361 内部插值滤波后峰值会有少量再生，门限最好留约 0.5 dB 余量。

**接收端**（你的 SFO 回退窗口、跟踪环和 CPE 都不动）

3. **用两个 LTS 平均做信道估计**
   - 你现在只用了一个 LTS（`rx_LTF_DATA(1:64)`）。
   - 两个 LTS 的回退窗口相同，线性相位也相同，可以直接相加，不需要去相位、平滑、再乘回去那一套。两个 LTS 只相隔 64 个采样点，40 ppm 下漂移约 0.003 个采样点，可以忽略。
   - 估计噪声减半。代价是多缓存一个 LTS，每帧 52 次复数加法再加一次移位。
4. **把 MMSE 做成 ZF 输出之后的一个实数加权**
   - 在 CPE 之后，对每个数据子载波再乘一个实数 β_k = |Ĥ_k|²/(|Ĥ_k|²+σ̂²)。它和 MMSE 在数学上完全等价。
   - β_k 每帧算一次，共 48 个值；每个样本只多 2 次实数乘法。前面的 ZF 除法、SFO 旋转、CPE 全都不改。
   - σ̂² 可以用两个 LTS 的差值估计：对 52 个子载波求 |L1−L2|² 的均值再除以 2，这正是第 3 条缓存 LTS 顺带得到的。
   - **一定要放在 CPE 之后**：你的 CPE 是 `Y*mean(pilotSeq./Y(pilotIndex))`，会同时校正幅度，如果先做 MMSE 缩放，CPE 会把它抵消掉。
   - 在你的近平坦信道下，β_k 基本是一个每帧一个的标量，收益可能比我之前在强选择性信道下测的 1 到 2 dB 小，需要仿真确认。成本很低，建议先预留。
5. **去掉 `QAM_softdemod` 和维特比译码**：CPE 之后的 `rx_QAM` 经过加权和解扰，按定点格式直接送进解码网络。

**训练端**

6. 用你的信道做微调：每帧一个 5 径瑞利实现、双 LTS 估计、MMSE 后缩放、I/Q 削波。这对应你说的非高斯噪声。平坦衰落下每帧 SNR 起伏很大，让解码器在这个分布上训练，才能保证深衰落帧也能平滑退化。

## 待仿真确认的数字

权限检查恢复后，我会先把这些加进 [ofdm_channel.py](ofdm_channel.py)：你的 5 径信道模型（时延用分数采样精确计算）、单/双 LTS 估计、LTS 差值估噪声、I/Q 分别削波、MMSE 后缩放。然后测三项：
- 单 LTS 和双 LTS 的 PSNR 差别；
- ZF 和 MMSE 后缩放在你的信道下的差别；
- I/Q 分别削波的最优门限。

长训练不受影响，还在后台跑。

### 用户 · 2026-09-28 10:35

> 可以，你就按这个方案跑一下仿真

**助手：**

Retrying the edits to `ofdm_channel.py`:

<details><summary>工具调用 × 4</summary>

- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py

</details>

**助手：**

Code changes are in. Next I'll make the ZF output saturate before the MMSE weighting, which matches the fixed-point order in hardware. Then I'll write the evaluation script for your receiver.

<details><summary>工具调用 × 7</summary>

- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Write` <work>\DeepJSCC-Q\ofdm_eval_user.py
- `Bash` Run receiver, clipping and combined sims for user's PHY
- `Edit` <work>\DeepJSCC-Q\ofdm_channel.py
- `Bash` Rerun user PHY simulations
- `Bash` Re-evaluate clipping with 4x-interpolated DAC peak
- `Edit` ~\.claude\projects\D--ClaudePrj-DeepJSCC-Q\memory\deployment-phy-constraints.md

</details>

**助手：**

仿真跑完了。最小改动方案的三项都有收益，合计约 +4 dB；但真正的大头损失来自平坦瑞利衰落本身，接收算法改不掉。

测试条件：长训练当前最好的模型（还没用 OFDM 信道微调），100 张验证图，每张图随机抽 4 到 8 次信道。信道用你 MATLAB 里的 5 径模型，按我的计算均方根时延扩展是 4.3 ns，基本是平坦衰落。结果在 `runs/ofdm_eval/user_rx.json`。

下文"整体 PSNR"指先平均所有图的 MSE 再换算，会被深衰落帧拉低；"逐图平均"是每张图算完 PSNR 再平均；"最差 5%"是逐图 PSNR 的 5% 分位数。

## 1. 接收端：双 LTS 平均 + MMSE 后缩放

平均 SNR 10 dB，不削波：

| 方案 | 整体 PSNR | 逐图平均 | 最差 5% |
|---|---|---|---|
| AWGN（参照） | 31.07 | 32.40 | 27.60 |
| 理想 CSI + ZF | 23.98 | 29.40 | 16.75 |
| **单 LTS + ZF（你现在的 RTL）** | **19.82** | 26.07 | 12.30 |
| 双 LTS 平均 + ZF | 21.21 | 27.59 | 13.81 |
| **双 LTS + MMSE 后缩放（σ² 用 LTS 差值估计）** | **21.97** | 27.79 | 14.59 |
| 双 LTS + MMSE（σ² 固定按 10 dB） | 21.97 | 27.79 | 14.53 |

- 双 LTS 平均带来 **+1.4 dB**，MMSE 后缩放再加 **+0.75 dB**，合计 +2.15 dB。最差 5% 的图像提升了 2.3 dB。SNR 为 5 dB 和 15 dB 时，提升幅度也差不多。
- 用 LTS 差值估计的 σ² 和用真实 σ² 效果一样。固定 σ² 在 10 dB 时没问题，但到 15 dB 会损失 1.4 dB，所以要用估计值。
- 理想 CSI 下 MMSE 和 ZF 没有区别，因为信道是平坦的。MMSE 的收益主要来自压制信道估计噪声。

## 2. 发射端：I/Q 削波门限

你的 IFFT 是 1 倍采样，削波后信号在 AD9361 内部插值时峰值会重新长出来：门限 ±2 时，p99 峰值会超出门限约 1.6 dB。所以我按"插值后的峰值"来算 DAC 满量程，下表用 p99.9 峰值口径，基准是不削波：

| I/Q 门限 | 插值后峰值 | 可提升的平均功率 | AWGN PSNR | 衰落信道 PSNR（双 LTS + MMSE） |
|---|---|---|---|---|
| 不削波 | 2.93 | 0 | 31.07 | 21.96 |
| ±2（你现在） | 2.63 | +0.95 dB | 31.38 | 22.80 |
| ±1.27 | 2.06 | +3.08 dB | **31.65** | 24.47 |
| **±1.13** | 1.89 | +3.84 dB | 31.58 | **24.94** |
| ±1.01 | 1.73 | +4.59 dB | 31.38 | 25.31 |

- AWGN 下最优门限约 ±1.27，衰落信道下偏好削得更狠。我建议折中取 **±1.13**（比每路 RMS 高约 5 dB）：
  - 相对你现在的 ±2，同样 DAC 满量程下 SNR 提高约 2.9 dB；
  - 衰落信道下整体 PSNR 提升约 2.1 dB，AWGN 下几乎不亏。
- 注意两点：
  - 你的 MATLAB 是对整个波形削波，包括 STF 和 LTF。门限降到 ±1.13 后，**只对 DATA 段削波**，不然会伤到 LTF 信道估计。
  - AD9361 的数字增益要按插值后的峰值约 1.9 对准 DAC 满量程，而不是按门限 1.13。

## 3. 汇总：改动清单（都基于你的 `PHY_80211a.m`）

| 位置 | 改动 | 硬件开销 |
|---|---|---|
| 发射端 | 比特扰码、卷积编码、交织换成**符号级置换加乘 j^r**（PAPR 降 5.7 dB，已验证） | 一张地址表，加取反和 I/Q 互换 |
| 发射端 | DATA 段 I/Q 削波门限从 ±2 改为 **±1.13**，数字增益按约 1.9 对准满量程 | 改常数 |
| 接收端 | 多取一个 LTS：窗口是 `startid_LTF-BACKOFF` 起的 64 点，回退相位和 LTS2 相同，**两次 FFT 结果直接平均** | 多缓存一个 LTS，每帧 52 次复加 |
| 接收端 | σ̂² = 对 52 个子载波求 \|L1−L2\|² 的均值再除以 2；β_k = \|Ĥ_k\|²/(\|Ĥ_k\|²+σ̂²) | 每帧 48 次除法，可以用串行除法器 |
| 接收端 | **在 SFO 跟踪和 CPE 之后**，数据子载波乘 β_k，然后解扰，送进解码器。去掉软解调和维特比 | 每个样本 2 次实数乘法 |
| 接收端 | SFO 回退窗口、跟踪环、CPE、ZF 除法 | **全部不动** |

说明：
- β_k 一定要放在 CPE 之后，因为你的 CPE `mean(pilotSeq./Y)` 会连幅度一起校正，放在前面会把 MMSE 缩放抵消掉。
- 两个 LTS 之间如果残留载波频偏，σ̂² 会略微偏大。你的 STF 频偏估计在正常 SNR 下精度足够，影响可以忽略。

三项叠加后，**整体 PSNR 从约 19.8 dB 提升到约 24 dB**。

## 4. 真正的大头：平坦瑞利衰落

AWGN 下是 31.07 dB，到理想 CSI 的衰落信道就只剩 23.98 dB，最差 5% 的图像只有 16.8 dB。这是整帧落入深衰落造成的，接收算法改不掉。可行的方向有三个，按代价从低到高：

1. **用衰落信道微调**：就是之前说的非高斯噪声训练。现在的模型只在 10 dB AWGN 下训练过，遇到深衰落帧（实际 SNR 可能只有 0 dB 左右）会退化得比较厉害。在衰落分布上微调，能明显改善低 SNR 帧，而且不改任何硬件。
2. **接收分集**：AD9361 本身是 2 发 2 收，两路接收做最大比合并（MRC），可以大幅压缩深衰落的概率。每个子载波多一次复乘加，外加第二路的 FFT 和 LTS 估计。这不算"最小改动"，但在平坦衰落下收益最大。
3. **信道模型本身偏悲观**：纯瑞利、没有直射径。实际室内多为带直射径的莱斯信道，衰落会轻得多。如果你有实测场景，可以换成莱斯模型再评估。

我的建议是：先按第 3 节把改动落进 MATLAB 和 RTL；等长训练结束（约 21:40），用这套链路（你的 5 径信道、双 LTS、MMSE 后缩放、±1.13 削波、扰码）做衰落微调，再看最差帧能提升多少，再决定要不要上接收分集。

### 用户 · 2026-09-28 10:42

> 信道相干时间比一帧短吗？如果不是，那么我们使用AWGN训练就是完全合理的，不需要再微调

**助手：**

不比一帧短，远长于一帧。所以对你这个近平坦信道，均衡后每一帧看到的就是 AWGN。我前面说要用"非高斯噪声"微调，在这个场景下不成立，用 AWGN 训练是合理的，OFDM 放进训练回路的微调可以不做。

## 相干时间和帧长

- **帧长**：683 个 OFDM 符号 × 4 µs ≈ 2.73 ms，加上前导码约 2.75 ms。
- **室内相干时间**：以人走动的速度 1 m/s 估算：

| 频段 | 最大多普勒频移 | 相干时间 |
|---|---|---|
| 5.8 GHz | 约 19 Hz | 约 9–22 ms |
| 2.4 GHz | 约 8 Hz | 约 22–53 ms |

相干时间按两个常用经验式估算：9/(16π·f_d) 和 0.423/f_d。

除非有东西以 3 m/s 以上的速度移动，一帧内信道都可以看成不变。你 MATLAB 里设的最大多普勒 = 0，也是这个假设。

## 为什么结论成立

信道在帧内不变，频率上又基本平坦（均方根时延扩展约 4.3 ns），均衡后每帧就是 y = x + n/h。这里 n/h 是白高斯噪声，只是每帧的 SNR 不同，等于 |h|²×平均 SNR。所以：
- **帧内**：就是 AWGN，没有非高斯的成分。
- **帧间**：只有 SNR 在变化。这是 SNR 分布的问题，不是噪声形状的问题。不用 OFDM 信道，在 AWGN 训练里就能处理。

## 剩下的非 AWGN 因素，都很小

1. **信道估计误差**：帧内固定不变，效果是每个子载波乘上一个微小的增益误差。扰码把它打散后，作用接近一点额外噪声。双 LTS 加 MMSE 已经把它压到了最小，不需要训练去适应。
2. **削波失真**：门限 ±1.13 时，没训练过的模型也只损失 0.1 到 0.5 dB，前面已经测过。
3. **MMSE 缩放带来的偏置**：仿真里没训练过的模型用 MMSE 反而比 ZF 高 0.75 dB，说明不需要为它专门训练。

## 唯一值得考虑的：训练 SNR 覆盖的范围

每帧 SNR 按瑞利分布起伏，部署时的平均 SNR 也不固定。现在的模型只在 10 dB 下训练过，在 AWGN 下测到：

| SNR | 5 dB | 10 dB | 15 dB |
|---|---|---|---|
| PSNR | 27.90 | 31.07 | 32.23 |

退化已经比较平滑。最终版论文的做法就是固定一个训练 SNR，解码器不输入 SNR，我们现在完全符合。如果以后想改善低 SNR 帧，可以在 AWGN 训练里每张图随机抽 SNR，比如 0 到 20 dB 均匀分布。这仍然是纯 AWGN 训练，代价是高 SNR 时会略有下降，要不要做看实测需求，现在不是必须。

## 结论

- **训练端**：维持现在的 AWGN 训练，长训练跑完就是最终浮点模型，接下来直接做定点化。
- **链路端**：上次那份最小改动清单照常落地：符号级扰码、DATA 段 I/Q 削波改到 ±1.13、双 LTS 平均、MMSE 后缩放。这些提升 SNR 或降低估计误差的改动，和训练方式无关。
- **深衰落帧**：整帧深衰落导致的低 PSNR 只能靠分集（AD9361 两路接收做 MRC）或实际莱斯信道缓解，这属于系统层面的取舍，和训练无关。

长训练预计 21:40 左右结束，我收到完成通知后把最终结果给你。

### 用户 · 2026-09-28 10:45

> 好的，那就这样了。等训练结束后进行定点化，现在先考虑一下定点化方案

**助手：**

先统计模型各部分的运算量，定点方案和资源估算都要用到：

<details><summary>工具调用 × 1</summary>

- `Bash` Count per-frame MACs and params for encoder/decoder

</details>

**助手：**

定点化方案我整理好了。先说对方案影响最大的一个发现：**ZU5EG 的计算资源非常宽裕**，所以不必像之前那样把所有地方都硬压到 W8A8。

## 基本数据（论文结构，256×256 输入）

| | 编码器 | 解码器 |
|---|---|---|
| 参数量 | 14.2 万 | 24.6 万 |
| 每帧乘加次数 | 0.94 G | 1.44 G |
| 30 fps 所需算力 | 28 GMAC/s | 43 GMAC/s |
| sigmoid 次数/帧 | 19.7 万 | 19.7 万 |
| 最大特征图 | 128×128×32 | 同 |

- **DSP 用量**：ZU5EG 有 1248 个 DSP48E2。按 250 MHz、每个 DSP 每周期一次乘加算，编码器只需约 113 个满负荷的 DSP（9%），解码器约 173 个（14%）。按 50–70% 的实际利用率算，也只占 15–30%。所以 **INT8 打包（一个 DSP 做两次乘法）不是必需的**，个别张量用 12 或 16 位完全可以接受。
- **片上存储**：权重按 INT8 存，编码器 142 KB、解码器 246 KB，都放得进片上存储。
- **流水结构**：整个网络只有 3×3 和 1×1 卷积、GDN、注意力、PixelShuffle，没有全局操作，可以做成逐层流水加行缓存的数据流结构，不需要缓存整帧特征图。唯一需要整帧缓存的是扰码前后的 latent：32768 个符号 × 6 bit ≈ 24 KB。

## 数值格式

| 对象 | 格式 | 说明 |
|---|---|---|
| 权重 | INT8 对称，**逐输出通道** | 缩放系数不限于 2 的幂 |
| 重量化 | 逐通道**整数乘法器（约 16 位）加移位** | 每个输出点只多一次乘法，约占乘加的 1/288。之前只用 2 的幂缩放，精度会浪费最多约 1 bit，这是旧方案 PTQ 掉 1.6 dB 的原因之一 |
| 激活 | 默认 INT8，逐张量对称 | 敏感张量按实测结果升到 12 或 16 位（混合精度） |
| 偏置和累加器 | INT32 | DSP48E2 的累加器是 48 位，不会溢出 |
| 舍入和溢出 | 舍入到最近（加 0.5 再移位），溢出处饱和 | 硬件几乎零成本，训练仿真和 RTL 必须一致 |
| 输入图像 | UINT8（0–255）直接进第一层 | |
| 输出图像 | 最后的 sigmoid 用查找表直接输出 UINT8 像素 | 输出本来就是 8 bit 图像，没有额外损失 |

## 非线性算子

- **LeakyReLU（斜率 1/128）**：在 INT32 累加器上直接做 x ≥ 0 ? x : x >>> 7，再重量化。这是精确的。
- **GDN（编码器 4 个）**：y = x · rsqrt(β + Σγ·x²)
  - x² 是精确的 16 位；γ 用 8 位无符号，把 CompressAI 重参数化后的等效值导出；
  - 求和是 32×32 的 1×1 卷积，外加 β；
  - rsqrt 的做法：前导零规格化，取尾数高 9 位查 512 项表，按指数奇偶选表，结果是 16 位；
  - 最后乘 x 再重量化。
- **逆 GDN（解码器 4 个）**：结构相同，查表换成 sqrt。
- **注意力门控 sigmoid**：先把门控分支输出量化到 INT8，再查 256 项表得到 UINT8（0 到 1）；和另一分支相乘得到 INT16，再重量化。
- **PixelShuffle**：只是重排地址，没有计算。
- **残差相加**：两路先对齐缩放系数（乘法器加移位），再做饱和加法。

## 信道接口

- **编码器输出到 QAM**：不需要算出星座点的值。每个分量和 7 个门限比较（0、±2d、±4d、±6d，其中 d = 1/√42，事先换算成整数），得到 3 bit 电平号，I 和 Q 合起来每个符号 6 bit。
- **符号扰码**：置换地址，乘 j^r 相当于电平号的取反和 I/Q 互换，都在电平号上完成，再交给你现有的发射通路映射成 DAC 值。
- **解码器输入**：接你接收机 MMSE 后缩放的输出。默认用 12 位 Q10（范围 ±2）直接进第一层，因为第一层只有 16 个输入通道，12 位不增加多少开销。也可以测一下 INT8 Q6 够不够用。

## 实施流程

1. **一套代码同时充当整数模型和训练仿真**：写一个"整数参考模型"，每个张量、每次舍入、每次饱和都和 RTL 一一对应。QAT 用的是同一个模块，只是在舍入处用直通梯度。这样可以避免上一轮的问题：伪量化训练和实际整数推理不一致，导出文件里自己标了"未验证逐比特一致"。
2. **PTQ 标定和逐张量敏感性分析**：每次只量化一个张量，看 PSNR 掉多少，据此决定哪些张量用 12 或 16 位。标定用百分位数加 MSE 搜索。
3. **QAT 微调**：可学习的缩放系数（LSQ 方法），AWGN 10 dB，保留 KL 项，从浮点最好模型开始训练 50 到 100 轮。按现在的速度约 30 分钟。
4. **逐比特一致的黄金模型和导出**：用 NumPy 整数运算实现一份参考模型，确认 PSNR 和第 3 步一致；再导出权重、偏置、乘法器、移位量、查找表（清单文件加 .coe/.mem），以及几张 Kodak 图逐层的输入输出向量，供 RTL 对比。
5. **目标**：整数模型相对浮点模型掉 ≤ 0.5 dB。上一轮是 1.24 dB，用的是旧模型和纯 2 的幂缩放。

## 需要你确认的问题

1. **重量化方式**：用"整数乘法器加移位"（我推荐，精度更好，资源也够），还是坚持"只移位"（RTL 最简单，但精度损失更大）？
2. **激活位宽策略**：默认 INT8，敏感处按实测升到 12 或 16 位，这样可以吗？还是你希望全网统一位宽，便于 RTL 复用同一个计算单元？
3. **你接收机均衡输出的定点格式**：多少位、小数位多少？这决定解码器输入怎么接。
4. **RTL 架构**：打算做逐层流水的数据流结构，还是一个共享计算阵列按层分时复用？这影响各层位宽统一的必要程度，以及片上缓存怎么估算。

长训练结束前，我可以先用当前的模型快照把第 1、2 步的框架搭起来，只做推理和少量计算，不影响训练。训练一结束就换成最终模型重新标定。

### 用户 · 2026-09-28 10:59

> 1.重量化可以使用整数乘法+移位，但是主要操作数位宽绝对不能超过DSPE2支持范围；2.我的想法是，如果你算出来DSP打包其实不必须，那么位宽就可以再提高一些，毕竟W8A12和W16A16都要用一个完整的DSPE2，而且wanhl

### 用户 · 2026-09-28 10:59

> [Request interrupted by user]

