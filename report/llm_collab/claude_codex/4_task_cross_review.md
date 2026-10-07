请审查设计报告 report/design_report.md（当前工作目录是仓库根目录 <work>\deepjsccq-ofdm-fpga）。
2.2 与 4.1 节是你起草、我（Claude Code）改过并合入的；其余部分是我写的。这是一次只读审查，不要修改任何文件。

## 审查重点
1. **数值核对**：报告中每个数值（资源、时序、功耗、EVM、PAPR、SNR、PSNR、CRC 正确率、帧率、时延、计数等）
   能否在仓库中找到出处并且一致。主要出处：
   - build/reports/（tx_/rx_ utilization/timing/power，network/ 下网络核 OOC 报告）
   - data/measurements/psnr_snr/k0802_v3_table.md、k0802_v3_da.json；fps/lat_video_10min_jscc2.json；latency/segments_3seg.json
   - data/model/manifest.json、checkpoint/summary.json
   - sim/network/results/*.log
   - src/hw/、src/sw/ 中的 RTL 与 Python（例如 PN 扰码多项式、SFO 环路系数、帧缓存容量、看门狗判据与参数、SSCC 包长）
   - PHY/射频的历史调试结论（EVM 逐项修复表、FIR、PAPR 分位数）没有放在仓库里的原始数据，只能对照代码检查可核对的部分；
     无法核对的请列为"仓库内无出处"，不要当作错误。
2. **我改动你的部分**是否引入错误或歪曲原意（例如删掉了"最终资源与相关实现对照"小节、改了脚注路径）。
3. **前后矛盾**：同一事实在不同章节的表述是否一致（例如 SSCC 悬崖区的 SNR 范围、时延定义、资源数）。
4. **过度结论**：哪些句子超出了数据能支持的范围。

## 输出格式
只在最终回复中给出一个按严重程度排序的列表，每条包含：
- 位置（报告中的小节号 + 原句片段）
- 问题类型：数值错误 / 无出处 / 矛盾 / 过度结论 / 表述
- 证据（文件路径 + 字段 / 行号 + 实际值）
- 建议改法
最后单列"已核对无误的数值"的简短清单。用简体中文。
