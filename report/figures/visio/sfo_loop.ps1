# SFO / CPE tracking loop (sfo_rotator.sv, CPE_compensation.sv, sfo_residual.sv).
#   powershell -ExecutionPolicy Bypass -File sfo_loop.ps1   -> sfo_loop.vsdx + ../hw/sfo_loop.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 180 70

$y = 6; $h = 30; $m = $y + $h / 2
[void](Label 1 ($m - 9) 14 8.5 ("信道均衡后`n每符号 64 点") 7 1 $ST.MUTE $false 2)
[void](Line 1 $m 15 $m)
[void](Box 15 $y 26 $h $ST.STORE ("FIFO 64`n（等待旋转因子）") $false 7)
[void](Line 41 $m 47 $m)
[void](Circle 51 $m 4 ([string][char]0x00D7) 11)
[void](Line 55 $m 66 $m)
[void](Box 66 $y 40 $h $ST.COMPUTE ("CPE_compensation`n4 个导频按极性求和 → 4G`n右移 2 位 → G`nreciprocal_cplx → 1/G`n保持 64 点，与数据复乘") $false 7)
[void](Line 106 $m 112 $m)
[void](Box 112 $y 40 $h $ST.COMPUTE ("sfo_residual（数据直通）`nL = −21·Im p₁₁ − 7·Im p₂₅`n+ 7·Im p₃₉ − 21·Im p₅₃`n21 = 16+4+1，7 = 8−1`n子载波 53 经过时输出 e") $false 7)
[void](Line 152 $m 160 $m)
[void](Label 160 ($m - 4) 19 8 ("→ 去导频`n→ 解码器") 7 0 $ST.INK)

# rotation factor generator
$ry = 44
[void](Box 30 $ry 42 18 $ST.COMPUTE ("相位发生器 + CORDIC`nph₀ = 32·A_pred（k = −32）`n每个子载波 ph ← ph − A_pred`nπ 缩放，2²⁹ = π，自然回绕") $false 7)
[void](Path @(51, $ry, 51, ($m + 4)))
[void](Label 52 ($ry - 6) 30 5 'cos / sin（12 b）' 7 0 $ST.MUTE)
[void](Box 96 $ry 56 18 $ST.WEIGHT ("环路更新（每个符号一次，令牌握手）`nR ← R + 170·e / 256      A ← A_pred + 170·e / 8`nA_pred = A + R；每帧第一个数据符号 A = R = 0") $false 7)
[void](Path @(132, ($y + $h), 132, $ry))
[void](Label 133 ($y + $h + 1) 30 5 'e_valid / e_data' 7 0 $ST.MUTE)
[void](Line 96 ($ry + 9) 72 ($ry + 9))
[void](Label 74 ($ry + 3) 22 5 'A_pred' 7 1 $ST.MUTE)
[void](Label 15 ($y + $h + 1) 50 5 'sfo_rotator' 8 0 $ST.MUTE $true)

Save-Figure (Join-Path $here 'sfo_loop.vsdx') (Join-Path $repo 'report\figures\hw\sfo_loop.png')
'saved'
