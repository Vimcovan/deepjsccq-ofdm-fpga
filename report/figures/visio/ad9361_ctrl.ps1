# AD9361 control: SPI bus ownership (ad9361_top.v) and the TX quadrature calibration phase search (ad9361_txq_search.v).
#   powershell -ExecutionPolicy Bypass -File ad9361_ctrl.ps1   -> ad9361_ctrl.vsdx + ../hw/ad9361_ctrl.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 180 118

# ---------------------------------------------------------------- (a) SPI ownership
[void](Label 2 1 80 6 '(a) SPI 总线归属（clk20）' 9 0 $ST.INK $true)
[void](Box 4 10 34 14 $ST.WEIGHT ("① ad9361_config`nLUT 初始化序列`n（RX 板：PS 执行）") $false 7)
[void](Box 4 30 34 14 $ST.COMPUTE ("② ad9361_txq_search`nTX 正交校准`n相位扫描（仅 TX 板）") $false 7)
[void](Box 4 50 34 14 $ST.GREEN ("③ PS 调试引擎`nSPI_CMD 翻转一次`n= 一次读 / 写") $false 7)
[void](Box 46 22 12 30 $ST.STORE ("三选一`n多路`n选择") $false 7)
foreach ($yy in 17, 37, 57) { [void](Line 38 $yy 46 ($yy * 0.5 + 18.5)) }
[void](Line 58 37 64 37)
[void](Box 64 30 16 14 $ST.COMPUTE ("ad9361_spi`n24 位`n20 MHz") $false 7)
[void](Line 72 44 72 50)
[void](Label 56 50 32 5 'spi_clk / csn / mosi / miso' 6.5 1 $ST.MUTE)
[void](Box 62 56 20 8 $ST.WEIGHT 'AD9361' $false 7.5)
[void](Label 4 68 80 32 ("归属：own_cfg = ~init_done → ①；`nown_txq = txq_busy → ②；否则 ③。`n`n①完成 → 自动启动②；②完成 → rf_ready = 1，`nLED 点亮，PS 才能发 SPI 命令。`n`nPS 等 SPI_STAT 中的传输计数加一后，`n再发下一条命令（跨 20 MHz 域）。") 7.5 0 $ST.INK)

# ---------------------------------------------------------------- (b) phase search flowchart
[void](Label 92 1 88 6 '(b) TX 正交校准相位扫描流程（PL 中实现）' 9 0 $ST.INK $true)
$cx = 92; $w = 78
function Step($y, $txt, $fill = $ST.COMPUTE, $h = 8) { [void](Box $cx $y $w $h $fill $txt $false 7) }
Step 9 'ENSM → ALERT（0x014），关闭 RX 正交跟踪（0x169[1:0] = 0）'
[void](Line 131 17 131 21)
Step 21 'p = 0' $ST.GRAY 6
[void](Line 131 27 131 31)
Step 31 ("0x0A0 = {NCO 频率, p}；0x0A1 软复位后恢复`n0x016 = 0x10 启动 TX 正交校准") $ST.COMPUTE 10
[void](Line 131 41 131 45)
Step 45 '轮询 0x016[4] == 0（超时则置 O_err）' $ST.COMPUTE 7
[void](Line 131 52 131 56)
Step 56 '0x0A7[1:0] == 2''b11 → 收敛图 field[p] = 1' $ST.COMPUTE 7
[void](Line 131 63 131 67)
[void](Diamond 131 70.5 30 9 $ST.WEIGHT 'p = 31 ?')
[void](Path @(146, 70.5, 176, 70.5, 176, 36, 170, 36))
[void](Label 170 52 10 9 ("否`np+1") 6.5 1 $ST.MUTE)
[void](Line 131 75 131 78)
[void](Label 132 73.5 10 4.5 '是' 6.5 0 $ST.MUTE)
Step 78 ("在 field 中找最长的循环连续段，取其中点`n（全不收敛 → 默认相位 4）") $ST.COMPUTE 10
[void](Line 131 88 131 92)
Step 92 '在选定相位上做最后一次校准' $ST.COMPUTE 7
[void](Line 131 99 131 103)
Step 103 ("恢复 0x169 / 0x014，等待 ENSM == FDD`nO_done = 1 → rf_ready") $ST.GREEN 10

Save-Figure (Join-Path $here 'ad9361_ctrl.vsdx') (Join-Path $repo 'report\figures\hw\ad9361_ctrl.png')
'saved'
