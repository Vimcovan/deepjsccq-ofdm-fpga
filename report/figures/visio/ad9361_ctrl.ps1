# AD9361 control: SPI bus ownership (ad9361_top.v) and the TX quadrature calibration phase search (ad9361_txq_search.v).
#   powershell -ExecutionPolicy Bypass -File ad9361_ctrl.ps1   -> ad9361_ctrl.vsdx + ../hw/ad9361_ctrl.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 186 118

# ---------------------------------------------------------------- (a) SPI ownership
[void](Label 2 1 80 6 '(a) SPI 总线归属（20 MHz 控制时钟域）' 9 0 $ST.INK $true)
[void](Box 4 10 34 14 $ST.WEIGHT ("① ad9361_config`nLUT 初始化序列`n（RX 板：PS 执行）") $false 7)
[void](Box 4 30 34 14 $ST.COMPUTE ("② ad9361_txq_search`nTX 正交校准`n相位扫描（仅 TX 板）") $false 7)
[void](Box 4 50 34 14 $ST.GREEN ("③ PS 发起的单次读写`n（PS 写 SPI 命令寄存器`n触发一次传输）") $false 7)
[void](Box 46 22 12 30 $ST.STORE ("三选一`n多路`n选择") $false 7)
foreach ($yy in 17, 37, 57) { [void](Line 38 $yy 46 ($yy * 0.5 + 18.5)) }
[void](Line 58 37 64 37)
[void](Box 64 30 16 14 $ST.COMPUTE ("ad9361_spi`n24 位`n20 MHz") $false 7)
[void](Line 72 44 72 50)
[void](Label 56 50 32 5 'spi_clk / csn / mosi / miso' 6.5 1 $ST.MUTE)
[void](Box 62 56 20 8 $ST.WEIGHT 'AD9361' $false 7.5)
[void](Label 4 68 80 32 ("归属：AD9361 的 PL 初始化未完成 → ①；`nTX 正交校准相位扫描进行中 → ②；否则 ③。`n`n①完成 → 自动启动②；②完成 → 射频就绪，`nLED 点亮，PS 才能发 SPI 命令。`n`nPS 写入一条命令后，等 SPI 状态寄存器中的`n传输计数加一，再发下一条（跨 20 MHz 时钟域）。") 7.5 0 $ST.INK)

# ---------------------------------------------------------------- (b) phase search flowchart
[void](Label 92 1 88 6 '(b) TX 正交校准相位扫描流程（PL 中实现）' 9 0 $ST.INK $true)
$cx = 92; $w = 78
function Step($y, $txt, $fill = $ST.COMPUTE, $h = 8) { [void](Box $cx $y $w $h $fill $txt $false 7) }
Step 9 ("ENSM 切到 ALERT 态（0x014：ENSM 配置 1）`n关闭 RX 正交跟踪（0x169：校准配置 1，[1:0] 写 0）") $ST.COMPUTE 10
[void](Line 131 19 131 22)
Step 22 '候选相位 p = 0' $ST.GRAY 6
[void](Line 131 28 131 31)
Step 31 ("0x0A0（正交校准 NCO 频率与相位）= {NCO 频率, p}`n0x0A1（正交校准控制）软复位后恢复`n0x016（校准控制）= 0x10：启动 TX 正交校准") $ST.COMPUTE 12
[void](Line 131 43 131 46)
Step 46 '轮询 0x016[4] 直到为 0（校准完成；超时则报错）' $ST.COMPUTE 7
[void](Line 131 53 131 56)
Step 56 '0x0A7（TX 正交校准状态）[1:0] == 2''b11 → 记录相位 p 收敛' $ST.COMPUTE 7
[void](Line 131 63 131 67)
[void](Diamond 131 70.5 30 9 $ST.WEIGHT 'p = 31 ?')
[void](Path @(146, 70.5, 176, 70.5, 176, 37, 170, 37))
[void](Label 177 52 9 9 ("否`np+1") 6.5 1 $ST.MUTE)
[void](Line 131 75 131 78)
[void](Label 132 73.5 10 4.5 '是' 6.5 0 $ST.MUTE)
Step 78 ("在收敛的相位中找最长的循环连续段，取其中点`n（全不收敛 → 默认相位 4）") $ST.COMPUTE 10
[void](Line 131 88 131 92)
Step 92 '在选定相位上做最后一次校准' $ST.COMPUTE 7
[void](Line 131 99 131 103)
Step 103 ("恢复 0x169 / 0x014 的原值，等待 ENSM 进入 FDD 态`n→ 射频就绪") $ST.GREEN 10

Save-Figure (Join-Path $here 'ad9361_ctrl.vsdx') (Join-Path $repo 'report\figures\hw\ad9361_ctrl.png')
'saved'
