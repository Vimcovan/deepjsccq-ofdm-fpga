# Visio 源图

报告与 README 中的网络示意图用 PowerShell 驱动 Microsoft Visio（COM）绘制，`.vsdx` 可直接在 Visio 中编辑。

| 脚本 | 输出 | 内容 |
|---|---|---|
| `fig02_network.ps1` | `fig02_network.vsdx`、`../network/fig02_network.png` | 编码器 / 解码器模块结构，各块输出尺寸取自 `data/model/manifest.json` |
| `fig06_branch_reuse.ps1` | `fig06_branch_reuse.vsdx`、`../network/fig06_branch_reuse.png` | RU、带投影旁路的 RG / RB、ATT 的分支输入复用 |
| `fig07_memory.ps1` | `fig07_memory.vsdx`、`../network/fig07_memory.png` | 按层并行度、权重 ROM 映射、激活缓存迁入 URAM（数据取自 manifest） |
| `visio_style.ps1` | — | 公共样式（宋体 + Times New Roman，浅色填充，与 `fig05_conv_engine.png` 一致）和绘图函数 |

```
powershell -ExecutionPolicy Bypass -File fig07_memory.ps1
```

PNG 按 300 dpi 导出。脚本含中文，须保存为带 BOM 的 UTF-8（Windows PowerShell 5.1）。
`fig05_conv_engine.png`（卷积引擎）为手绘图，不由脚本生成。
