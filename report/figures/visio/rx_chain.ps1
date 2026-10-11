# OFDM RX chain (rx_baseband_top.sv).
#   powershell -ExecutionPolicy Bypass -File rx_chain.ps1   -> rx_chain.vsdx + ../hw/rx_chain.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 180 96

function Sig($x1, $y, $x2, $txt) {
  [void](Line $x1 $y $x2 $y)
  [void](Label $x1 ($y - 9) ($x2 - $x1) 8.5 $txt 7 1 $ST.MUTE $false 2)
}

# ---------------------------------------------------------------- row 1: synchronizer_top
$y = 12; $h = 30; $m = $y + $h / 2
[void](Label 22 2 120 5 'synchronizer_top' 8 0 $ST.MUTE $true)
[void](Box 20 7 136 39 $null '' $true 8 '0.5 pt')
[void](Label 1 ($m - 9) 18 8.5 ("ADC FIFO`n{Q,I} 24 b") 7 1 $ST.MUTE $false 2)
[void](Line 1 $m 23 $m)
[void](Box 23 $y 46 $h $ST.COMPUTE ("frame_detection`nSTF 延迟自相关（滞后 16）`n2 个复乘 + 16 点滑窗 → P、E`nCORDIC → |P|、∠P`n|P| > E/2 且 E > 250，连续 64 点`nDDS 按 ∠P/16 纠正 CFO") $false 7)
Sig 69 $m 76 '24 b'
[void](Box 76 $y 42 $h $ST.COMPUTE ("time_sync`nLTF 匹配滤波：Gauss 复数乘法`n（3 个实数 FIR）`n|X|² > 0.375 E 且 E > 2500`n系数循环移位 9 → 窗口`n提前 8 个采样（落在 CP 内）") $false 7)
Sig 118 $m 124 '24 b'
[void](Box 124 $y 29 $h $ST.STORE ("cp_remover`n先放行 LTF1、LTF2`n（2 × 64）`n之后每 80 个`n丢弃前 16 个") $false 7)
[void](Line 153 $m 160 $m)
[void](Box 160 ($y + 5) 18 20 $ST.COMPUTE ("FFT IP`n64 点`n不缩放`n+ fftshift") $false 7.5)
[void](Path @(169, ($y + 25), 169, 52, 10, 52, 10, 70, 14, 70))

# ---------------------------------------------------------------- row 2: equalizer_top + framer
$y = 56; $h = 28; $m = $y + $h / 2
[void](Label 16 ($y + $h + 1) 120 5 'equalizer_top' 8 0 $ST.MUTE $true)
[void](Box 14 $y 26 $h $ST.COMPUTE ("channel_`nequalization`nLTF1 存 RAM`n与 LTF2 平均 → Ĥ`n1/Ĥ 重复 683 次`n逐子载波复乘") $false 6.5)
Sig 40 $m 46 '24 b'
[void](Box 46 $y 22 $h $ST.COMPUTE ("sfo_rotator`n× exp(−j·k·A_pred)`nCORDIC + 复乘") $false 7)
Sig 68 $m 74 '24 b'
[void](Box 74 $y 24 $h $ST.COMPUTE ("CPE_`ncompensation`n4 导频求和 → G`n× 1/G（保持 64 点）") $false 7)
Sig 98 $m 104 '24 b'
[void](Box 104 $y 22 $h $ST.COMPUTE ("sfo_residual`n导频 LS 斜率 L`n（移位相加）") $false 7)
[void](Path @(115, ($y + $h), 115, ($y + $h + 6), 57, ($y + $h + 6), 57, ($y + $h)))
[void](Label 60 ($y + $h + 1.5) 54 4.5 '相位误差 e（每个符号一次）' 7 1 $ST.INK)
Sig 126 $m 132 '24 b'
[void](Box 132 $y 24 $h $ST.STORE ("去导频`nrx_jscc_framer`n去 16 个补零`nPN 解扰`n置 tlast / tuser") $false 7)
[void](Line 156 $m 162 $m)
[void](Box 162 ($y + 4) 17 20 $ST.STORE ("→ URAM`n帧缓存`n（整帧丢弃`n模式）") $false 7)

Save-Figure (Join-Path $here 'rx_chain.vsdx') (Join-Path $repo 'report\figures\hw\rx_chain.png')
'saved'
