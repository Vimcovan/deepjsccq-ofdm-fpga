---
name: pl-counter-latency
description: Use to measure per-stage latency of a streaming FPGA pipeline (Zynq / PYNQ) — including across two boards linked only by radio — without ILA or extra RTL, by polling existing PL frame / byte counters from the PS, time-stamping every change, estimating the clock offset between boards, and pairing events frame by frame with causal windows. Gives latency CDFs that exclude PS scheduling jitter.
---

# 用 PL 计数器做分段时延测量（含跨板）

## 适用场景

- 数据流从信源到射频全在 PL 中（例如编码器 → OFDM → 空口 → 接收 → 解码器），想按段给出时延（编码 / 传输 / 解码），
  而不是把 PS 软件的调度抖动算进 FPGA 的指标。
- 不想加 ILA、不想改 RTL：PL 里已经有帧计数器、字节计数器（调试 / 遥测用的寄存器）。
- 两块板之间只有射频链路和一根普通网线，时钟不同步。

## 使用方法

1. **先读 RTL，确认每个计数器在哪一拍加 1**：是"第一个样点写入"还是"最后一个符号送出"，是帧还是字节；写进脚本开头的注释。
   计数器语义弄错，后面的配对全错。
2. **PS 紧循环轮询**（本例每 40 µs 一轮）：每个计数器值变化就记一条 `(time.time(), 名称, 值)`。字节计数器按"连续 ≥ 1 ms 无增长"
   切成突发，得到每帧的首 / 尾时刻；32 位计数器会回绕，不要用"值 ÷ 帧长"判断帧号。
3. **跨板时钟偏差**：RX 板每 5 s 向 TX 板发一次时间查询，`偏差 = TX 时间 − (发出 + 收到) / 2`，同时记录往返时间（RTT）；
   之后按时间线性插值，把 TX 事件换算到 RX 时钟。偏差的误差上限约为 RTT / 2（本例 RTT 中位数 0.58 ms）。
4. **按数据流的因果窗口配对**，而不是"找最近的事件"：帧间隔 33 ms 时最近匹配会配错帧。为每一段规定物理上可能的时延窗口
   （例：编码器输入首字节 → 输入末字节 20–40 ms；输入末字节 → 最后一个编码符号 0–15 ms；同步 → 解码完成 5–70 ms），
   对每个前级事件取窗口内的第一个后级事件；窗口外记为缺失。
5. **合并成与对比文献一致的段**（本例按 GLOBECOM 2025 的三段：编码 / 传输 / 解码），段与段首尾相接，合计 = 首段起点到末段终点。
6. 输出每段的中位数、1 % / 99 % 分位和样本数，画 CDF；样本数在各段可能不同（配对失败的帧被剔除），要分别报告。
7. 极少数离群值通常是 PS 轮询被抢占造成的打点延迟，看 CDF 两端即可识别；不要把它们解释为硬件行为。

脚本：`board/tests/pl_events.py`（两板各运行一份，只读寄存器，可与正常服务同时运行）→ `seg_latency.py`（PC 上配对）→ `plot_seg_cdf.m`。

## 已验证效果

本项目 DeepJSCC-Q 链路，约 90 s、1701 帧（编码段 1706）：编码 38.20 ms、传输 2.87 ms（下限 2.748 ms 正是一帧的空中时间）、解码 30.39 ms，
PL 合计 71.47 ms，1 % – 99 % 分位宽度均在 0.2 ms 以内（`data/measurements/latency/`）。
测量全程服务照常运行，没有改 RTL，也没有用 ILA。

## 来源（从哪次失败中总结）

最初在 RX 的 PS 上按"收到重建图的时间 − TX 发图时间"统计时延和帧率：结果混入了 PS 调度抖动，SSCC（JPEG 在 PS 上）与 DeepJSCC-Q 的比较也不公平；
按"最像的预览帧"配对时，视频循环和静止画面会配错帧，出现异常尖峰。用户指出 PS 调度抖动不应计入 FPGA 指标，
并要求参照对比论文的测法。改为读 RTL 确认计数器时机 → 两板轮询 PL 计数器 → 因果窗口配对；
其间还发现 32 位字节计数器回绕导致"值 ÷ 帧长"的帧号判断出错，改为按空闲间隙切分。
