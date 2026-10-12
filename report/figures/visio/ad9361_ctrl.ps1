# AD9361 control: SPI bus ownership (ad9361_top.v) and the TX quadrature calibration phase search (ad9361_txq_search.v).
#   powershell -ExecutionPolicy Bypass -File ad9361_ctrl.ps1   -> ad9361_ctrl.vsdx + ../hw/ad9361_ctrl.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 186 132

# ---------------------------------------------------------------- (a) SPI ownership
[void](Label 2 1 80 6 '(a) SPI 总线归属（20 MHz 控制时钟域）' 9 0 $ST.INK $true)
function KBox($x, $y, $w, $h, $kind, $text) {
  $s = Box $x $y $w $h $null $text $false 7
  Fc-Style $s $kind; $s.CellsU('Rounding').FormulaU = '1.5 mm'
}
KBox 4 10 34 14 'DEC' ("① ad9361_config`nLUT 初始化序列`n（RX 板：PS 执行）")
KBox 4 30 34 14 'PROC' ("② ad9361_txq_search`nTX 正交校准`n相位扫描（仅 TX 板）")
KBox 4 50 34 14 'TERM' ("③ PS 发起的单次读写`n（PS 写 SPI 命令寄存器`n触发一次传输）")
# 3:1 MUX trapezoid (wide side towards the three sources)
$mx = @(46, 12, 60, 24, 60, 50, 46, 62, 46, 12)
$mux = Path $mx $false
$mux.CellsU('Geometry1.NoFill').FormulaU = 'FALSE'; Fc-Style $mux 'INIT'
$mux.Text = "三`n选`n一"; Style-Text $mux 7
foreach ($yy in 17, 37, 57) { [void](Line 38 $yy 46 $yy) }
[void](Line 60 37 66 37)
KBox 66 30 18 14 'PROC' ("ad9361_spi`n24 位`n20 MHz")
[void](Line 75 44 75 50)
[void](Label 59 50 32 5 'spi_clk / csn / mosi / miso' 6.5 1 $ST.MUTE)
KBox 65 56 20 8 'ALT' 'AD9361'
[void](Label 4 68 80 32 ("归属：AD9361 的 PL 初始化未完成 → ①；`nTX 正交校准相位扫描进行中 → ②；否则 ③。`n`n①完成 → 自动启动②；②完成 → 射频就绪，`nLED 点亮，PS 才能发 SPI 命令。`n`nPS 写入一条命令后，等 SPI 状态寄存器中的`n传输计数加一，再发下一条（跨 20 MHz 时钟域）。") 7.5 0 $ST.INK)

# ---------------------------------------------------------------- (b) phase search flowchart
[void](Label 92 1 88 6 '(b) TX 正交校准相位扫描流程（PL 中实现）' 9 0 $ST.INK $true)
$cx = 131
[void](FTerm $cx 9 7 '① 初始化序列执行完毕')
[void](Line $cx 16 $cx 20)
[void](FProc $cx 20 10 ("ENSM 切到 ALERT 态（0x014：ENSM 配置 1）`n关闭 RX 正交跟踪（0x169：校准配置 1，[1:0] 写 0）"))
[void](Line $cx 30 $cx 33)
[void](FProc $cx 33 6 '候选相位 p = 0' 'INIT')
[void](Line $cx 39 $cx 42)
$cal = FProc $cx 42 12 ("0x0A0（正交校准 NCO 频率与相位）= {NCO 频率, p}`n0x0A1（正交校准控制）软复位后恢复`n0x016（校准控制）= 0x10：启动 TX 正交校准")
[void](Line $cx 54 $cx 57)
[void](FProc $cx 57 7 '轮询 0x016[4] 直到为 0（校准完成；超时则报错）')
[void](Line $cx 64 $cx 67)
[void](FProc $cx 67 7 '0x0A7（TX 正交校准状态）[1:0] == 2''b11 → 记录相位 p 收敛')
[void](Line $cx 74 $cx 77)
[void](FDec $cx 81.5 30 9 'p = 31 ?')
[void](Path @(($cx + 15), 81.5, 176, 81.5, 176, 48, $cal.R, 48))
[void](Label 177 63 9 9 ("否`np+1") 6.5 1 $ST.MUTE)
[void](Line $cx 86 $cx 90)
[void](Label ($cx + 1) 85.5 10 4.5 '是' 6.5 0 $ST.MUTE)
[void](FProc $cx 90 10 ("在收敛的相位中找最长的循环连续段，取其中点`n（全不收敛 → 默认相位 4）"))
[void](Line $cx 100 $cx 103)
[void](FProc $cx 103 7 '在选定相位上做最后一次校准')
[void](Line $cx 110 $cx 113)
[void](FProc $cx 113 7 '恢复 0x169 / 0x014 的原值，等待 ENSM 进入 FDD 态')
[void](Line $cx 120 $cx 123)
[void](FTerm $cx 123 7 '射频就绪（LED 点亮）')

Save-Figure (Join-Path $here 'ad9361_ctrl.vsdx') (Join-Path $repo 'report\figures\hw\ad9361_ctrl.png')
'saved'
