# OFDM TX chain (tx_baseband_jscc.sv) + 20 MSPS gate FSM (jscc_tx_ps_top.sv).
#   powershell -ExecutionPolicy Bypass -File tx_chain.ps1   -> tx_chain.vsdx + ../hw/tx_chain.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 180 102

function Sig($x1, $y, $x2, $txt) {           # arrow with a signal label above it
  [void](Line $x1 $y $x2 $y)
  [void](Label $x1 ($y - 9) ($x2 - $x1) 8.5 $txt 7 1 $ST.MUTE $false 2)
}

# ---------------------------------------------------------------- row 1
$y = 14; $h = 20; $m = $y + $h / 2
[void](Label 2 ($m - 9) 20 8.5 ("来自 CDC`n{Q,I} 24 b") 7 1 $ST.MUTE $false 2)
[void](Line 2 $m 22 $m)
[void](Box 22 $y 32 $h $ST.COMPUTE ("tx_jscc_framer`n计数分帧：32768 个`n符号 + 16 个零`niq_pn_scrambler`nPN 符号翻转") $false 7.5)
Sig 54 $m 62 '24 b'
[void](Box 62 $y 26 $h $ST.COMPUTE ("pilot_insert`n64 子载波计数`n空子载波填 0`n导频 ±1024") $false 7.5)
Sig 88 $m 96 '24 b'
[void](Box 96 $y 22 $h $ST.STORE ("fft_ifft_shift`n交换前后两半`n（FIFO 32）") $false 7.5)
Sig 118 $m 127 '2×16 b'
[void](Box 127 $y 26 $h $ST.COMPUTE ("IFFT IP`n64 点，流水`n不缩放`n插入 CP 16") $false 7.5)
[void](Path @(153, $m, 174, $m, 174, ($y + $h + 6), 10, ($y + $h + 6), 10, 54, 16, 54))
[void](Label 153 ($m - 9) 21 8.5 '2×19 b' 7 1 $ST.MUTE $false 2)

# ---------------------------------------------------------------- row 2
$y = 44; $m = $y + $h / 2
[void](Box 16 $y 26 $h $ST.COMPUTE ("truncation_and_`nsaturation`n+半 LSB，>>4`n饱和到 12 位") $false 7.5)
Sig 42 $m 50 '24 b'
[void](Box 50 $y 26 $h $ST.WEIGHT ("preamble_insert`n前导 ROM 320 点`n（STF + LTF）`n帧末置 tlast") $false 7.5)
Sig 76 $m 84 '24 b + tlast'
[void](Box 84 $y 26 $h $ST.STORE ("uram_frame_fifo`n包模式，6 URAM`n整帧写完才放行`n满则反压") $false 7.5)
Sig 110 $m 116 '24 b'
[void](Box 116 $y 28 $h $ST.COMPUTE ("20 MSPS 发送门控`n帧间隔 50 µs → 发送`n每 5 拍放行 1 个`n帧首 8 个连续放行") $false 7.5)
[void](Line 144 $m 160 $m)
[void](Label 143 ($m - 13) 18 12.5 ("I/Q 数据`n+ 握手") 6.5 1 $ST.MUTE $false 2)
[void](Box 160 ($y + 4) 18 12 $ST.STORE ("AD9361 侧`nDAC FIFO") $false 7)

# ---------------------------------------------------------------- gate FSM
$fy = 88
[void](Label 2 ($fy - 4) 40 6 '发送门控状态机：' 8 0 $ST.INK $true)
[void](Circle 52 $fy 4 '间隔' 7)
[void](Circle 90 $fy 4 ([string]"等待") 7)
[void](Circle 128 $fy 4 '发送' 7)
# reset -> GAP; arcs between the states (RTL: jscc_tx_ps_top.sv, src_st)
[void](Line 52 ($fy - 12) 52 ($fy - 4))
[void](Label 53 ($fy - 14) 10 5 '复位' 7 0 $ST.MUTE)
[void](Arc 55.5 ($fy - 2) 86.5 ($fy - 2) 6)
[void](Label 56 ($fy - 13) 30 5 '间隔计满 5000 拍' 7 1 $ST.MUTE)
[void](Arc 93.5 ($fy - 2) 124.5 ($fy - 2) 6)
[void](Label 94 ($fy - 13) 30 5 '1 拍后' 7 1 $ST.MUTE)
[void](Arc 126 ($fy + 3.5) 54 ($fy + 3.5) 10)
[void](Label 60 ($fy + 14) 60 5 '已送出 54960 个采样' 7 1 $ST.MUTE)

Save-Figure (Join-Path $here 'tx_chain.vsdx') (Join-Path $repo 'report\figures\hw\tx_chain.png')
'saved'
