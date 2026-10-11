# RTL composition of the RG (with projection skip), RU and ATT blocks (gen_rtl_top.py output).
#   powershell -ExecutionPolicy Bypass -File block_rtl.ps1   -> block_rtl.vsdx + ../hw/block_rtl.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$X = [char]0x00D7

Open-Visio 180 150

function B($x, $y, $w, $txt, $fill = $ST.COMPUTE, $h = 10) { [void](Box $x $y $w $h $fill $txt $false 6.5) }
function Wire($x1, $x2, $y) { [void](Line $x1 $y $x2 $y) }

# ---------------------------------------------------------------- (a) RG
$o = 2
[void](Label 2 $o 176 5 '(a) RG，带投影旁路（例：enc.0，步长 2）' 8.5 0 $ST.INK $true)
$y = $o + 9; $m = $y + 5
[void](Label 1 ($m - 3) 8 6 '输入' 7 1)
Wire 8 12 $m
B 12 $y 18 ("行缓存`nK=3，S=2") $ST.STORE
Wire 30 34 $m; [void](Dot 32 $m)
B 34 $y 22 ("conv_engine`n3" + $X + "3，leaky")
Wire 56 60 $m
B 60 $y 16 ("行缓存`nK=3") $ST.STORE
Wire 76 80 $m
B 80 $y 20 ("conv_engine`n3" + $X + "3")
Wire 100 104 $m
B 104 $y 20 ("axis_gdn`nGDN")
[void](Path @(124, $m, 160, $m, 160, ($m + 5)))
[void](Circle 160 ($m + 9) 4 '+' 9)
[void](Line 164 ($m + 9) 172 ($m + 9)); [void](Label 172 ($m + 6) 8 6 '输出' 7 0)
$y2 = $y + 14; $m2 = $y2 + 5
[void](Path @(32, $m, 32, $m2, 40, $m2))
B 40 $y2 20 ("centre_tap`n取中心抽头")
Wire 60 66 $m2
B 66 $y2 24 ("conv_engine`n1" + $X + "1 投影旁路")
Wire 90 96 $m2
B 96 $y2 28 ("axis_fifo_packed`n旁路对齐") $ST.STORE
[void](Path @(124, $m2, 160, $m2, 160, ($m + 13)))
[void](Label 126 ($m + 4) 32 5 'axis_add：两路各乘重定标系数，相加后移位' 6.5 0 $ST.MUTE)

# ---------------------------------------------------------------- (b) RU
$o = 38
[void](Label 2 $o 176 5 ('(b) RU，上采样（例：dec.7，r = 2，主路首个卷积与旁路合并为一个引擎）') 8.5 0 $ST.INK $true)
$y = $o + 9; $m = $y + 5
[void](Label 1 ($m - 3) 8 6 '输入' 7 1)
Wire 8 12 $m
B 12 $y 16 ("行缓存`nK=3") $ST.STORE
Wire 28 32 $m
B 32 $y 30 ("conv_engine（合并）`n3" + $X + "3，256 通道，P = 52")
Wire 62 66 $m
B 66 $y 16 ("axis_split`n128 | 128")
[void](Path @(82, $m, 86, $m))
B 86 $y 20 ("pixel_shuffle`nr = 2")
Wire 106 110 $m
B 110 $y 14 ("行缓存`nURAM") $ST.STORE
Wire 124 128 $m
B 128 $y 14 ("conv`n3" + $X + "3")
Wire 142 145 $m
B 145 $y 12 ("IGDN")
[void](Path @(157, $m, 162, $m, 162, ($m + 5)))
[void](Circle 162 ($m + 9) 4 '+' 9)
[void](Line 166 ($m + 9) 172 ($m + 9)); [void](Label 172 ($m + 6) 8 6 '输出' 7 0)
$y2 = $y + 14; $m2 = $y2 + 5
[void](Path @(74, ($y + 10), 74, $m2, 86, $m2))
B 86 $y2 20 ("pixel_shuffle`nr = 2")
Wire 106 110 $m2
B 110 $y2 32 ("axis_fifo_packed（URAM）`n旁路对齐") $ST.STORE
[void](Path @(142, $m2, 162, $m2, 162, ($m + 13)))

# ---------------------------------------------------------------- (c) ATT
$o = 74
[void](Label 2 $o 176 5 ('(c) ATT（例：enc.3）：两支路首个 1' + $X + '1 合并；每支路 3 个瓶颈残差单元') 8.5 0 $ST.INK $true)
$y = $o + 10; $m = $y + 5
[void](Label 1 ($m - 3) 8 6 'x' 8 1)
Wire 6 10 $m; [void](Dot 8 $m)
B 10 $y 14 ("像素缓存`n1" + $X + "1") $ST.STORE
Wire 24 28 $m
B 28 $y 22 ("conv_engine（合并）`n1" + $X + "1，32 通道")
Wire 50 54 $m
B 54 $y 14 ("axis_split`n16 | 16")
# branch A
$ya = $y - 2; $ma = $ya + 5
[void](Path @(68, ($m - 2), 72, ($m - 2), 72, $ma, 76, $ma))
B 76 $ya 50 ("A 支路：3 个瓶颈单元`n（1" + $X + "1 → 3" + $X + "3 → 1" + $X + "1，各带残差相加）")
# branch B
$yb = $y + 13; $mb = $yb + 5
[void](Path @(68, ($m + 2), 70, ($m + 2), 70, $mb, 76, $mb))
B 76 $yb 50 ("B 支路：3 个瓶颈单元`n+ 1" + $X + "1 卷积")
Wire 126 130 $mb
B 130 $yb 16 ("axis_sigmoid`n32 段") $ST.OPTION
# gate
B 152 ($y + 4) 18 ("axis_gate`nx + a·σ(b)") $ST.WEIGHT 12
[void](Path @(126, $ma, 156, $ma, 156, ($y + 4)))
[void](Path @(146, $mb, 161, $mb, 161, ($y + 16)))
[void](Line 170 ($y + 10) 176 ($y + 10))
# identity x
$yx = $y + 28; $mx = $yx + 5
[void](Path @(8, $m, 8, $mx, 76, $mx))
B 76 $yx 50 ("axis_fifo_packed：x 的对齐 FIFO") $ST.STORE
[void](Path @(126, $mx, 166, $mx, 166, ($y + 16)))

# ---------------------------------------------------------------- legend / note
$ly = 127
[void](Box 4 $ly 5 3.5 $ST.COMPUTE '' $false 6 '0.5 pt'); [void](Label 10 ($ly - 0.8) 30 5 '计算模块' 7 0)
[void](Box 34 $ly 5 3.5 $ST.STORE '' $false 6 '0.5 pt'); [void](Label 40 ($ly - 0.8) 40 5 '缓存（行缓存、对齐 FIFO）' 7 0)
[void](Box 82 $ly 5 3.5 $ST.WEIGHT '' $false 6 '0.5 pt'); [void](Label 88 ($ly - 0.8) 30 5 '门控' 7 0)
[void](Box 104 $ly 5 3.5 $ST.OPTION '' $false 6 '0.5 pt'); [void](Label 110 ($ly - 0.8) 40 5 '非线性（分段线性）' 7 0)
[void](Label 4 ($ly + 5) 174 10 ('每个 conv_engine 自带权重 ROM 与重定标参数；所有连线都是 AXI-Stream（valid / ready / tlast / tuser）。RB 的结构与 (a) 相同，但第二个卷积后没有 GDN，旁路为恒等（只有对齐 FIFO）。') 7 0 $ST.MUTE)

Save-Figure (Join-Path $here 'block_rtl.vsdx') (Join-Path $repo 'report\figures\hw\block_rtl.png')
'saved'
