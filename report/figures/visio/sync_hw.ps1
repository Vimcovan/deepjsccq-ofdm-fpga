# Hardware structure of frame_detection.sv (a) and time_sync.sv (b).
#   powershell -ExecutionPolicy Bypass -File sync_hw.ps1   -> sync_hw.vsdx + ../hw/fd_hw.png, ../hw/ts_hw.png (two pages)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$ST.SIZE = 7

function Sig($x1, $y, $x2, $txt) { [void](Line $x1 $y $x2 $y); if ($txt) { [void](Label $x1 ($y - 6) ($x2 - $x1) 5.5 $txt 6.5 1 $ST.MUTE $false 2) } }

# ================================================================= (a) frame detection
Open-Visio 180 64
[void](Label 0 17 8 6 'r(n)' 7.5 1)
[void](Line 2 24 8 24)
[void](Box 8 14 10 20 $ST.STORE ("广播") $false 7)
# delay + products
[void](Path @(18, 19, 22, 19))
[void](Box 22 14 14 10 $ST.STORE ("延迟 16`n（SRL）") $false 6.5)
[void](Path @(36, 19, 40, 19))
[void](Path @(20, 19, 20, 9, 46, 9, 46, 13))
[void](Box 40 13 20 9 $ST.COMPUTE ("复乘`nr(n)·r*(n−16)") $false 6.5)
[void](Path @(38, 19, 38, 28, 40, 28))
[void](Box 40 24 20 9 $ST.COMPUTE ("复乘`n|r(n−16)|²") $false 6.5)
Sig 60 17.5 66 ''
Sig 60 28.5 66 ''
[void](Box 66 13 20 9 $ST.COMPUTE ("16 点滑窗求和`n（实部、虚部）") $false 6.5)
[void](Box 66 24 20 9 $ST.COMPUTE ("16 点滑窗求和") $false 6.5)
Sig 86 17.5 92 'P'
Sig 86 28.5 92 'E'
[void](Box 92 13 18 9 $ST.COMPUTE ("CORDIC IP`n|P|、∠P") $false 6.5)
[void](Box 92 24 18 9 $ST.STORE ("寄存 8 级`n（对齐）") $false 6.5)
Sig 110 17.5 116 ''
Sig 110 28.5 116 ''
[void](Box 116 12 26 22 $ST.WEIGHT ("判决`n|P| > E/2（移位）`nE > 250`n连续 64 点 → 检测`n状态机 HOLD / OUTPUT") $false 6.5)
[void](Path @(129, 12, 129, 6, 150, 6, 150, 12))
[void](Label 130 1 20 5 '∠P ≫ 4' 6.5 1 $ST.MUTE)
[void](Box 142 12 18 10 $ST.COMPUTE ("DDS IP`n相位增量") $false 6.5)
[void](Path @(151, 22, 151, 38))
[void](Label 152 28 20 5 'cos / sin' 6.5 0 $ST.MUTE)
# data path
[void](Path @(13, 34, 13, 43, 22, 43))
[void](Box 22 38 50 10 $ST.STORE ("FIFO 128（等待检测与 CFO 估计）") $false 6.5)
[void](Path @(72, 43, 116, 43))
[void](Box 116 38 26 10 $ST.GRAY ("OUTPUT 时放行`n一帧 + 100 个余量") $false 6.5); [void](Line 129 34 129 38)
[void](Path @(142, 43, 146, 43))
[void](Box 146 38 18 10 $ST.COMPUTE ("复乘`n纠正 CFO") $false 6.5)
[void](Line 164 43 170 43)
[void](Label 170 39 10 8 ("→ 定时`n同步") 6.5 0)
[void](Label 4 52 172 10 ("复乘结果先取 14 位、再饱和到 12 位；∠P 是 16 个采样内的载波相位差，右移 4 位即每个采样的相位增量。归一化门限 E/2 只需右移一位，不用除法器。") 7 0 $ST.MUTE)
Save-Figure (Join-Path $here 'sync_hw_fd.vsdx') (Join-Path $repo 'report\figures\hw\fd_hw.png')

# ================================================================= (b) LTF timing
Open-Visio 180 64
[void](Label 1 18 10 6 'r(n)' 7.5 1)
[void](Line 2 24 8 24)
[void](Box 8 8 10 34 $ST.STORE ("广播") $false 7)
# FIRs
[void](Path @(18, 12, 24, 12)); [void](Box 24 8 30 8 $ST.COMPUTE ("FIR（系数 c）对 I → k₁") $false 6.5)
[void](Path @(18, 21, 24, 21)); [void](Box 24 17 30 8 $ST.COMPUTE ("FIR（系数 d）对 Q → k₂") $false 6.5)
[void](Path @(18, 30, 24, 30)); [void](Box 24 26 30 8 $ST.COMPUTE ("FIR（系数 c+d）对 I+Q → k₃") $false 6.5)
[void](Path @(54, 12, 58, 12)); [void](Path @(54, 21, 58, 21)); [void](Path @(54, 30, 58, 30))
[void](Box 58 8 26 26 $ST.COMPUTE ("Gauss 复数乘法`nRe = k₁ − k₂`nIm = k₃ − k₁ − k₂`n→ X(n)") $false 6.5)
Sig 84 21 90 ''
[void](Box 90 15 18 12 $ST.COMPUTE ("复乘`n|X(n)|²") $false 6.5)
# energy
[void](Path @(13, 42, 13, 47, 24, 47))
[void](Box 24 42 22 10 $ST.COMPUTE ("复乘 |r(n)|²") $false 6.5)
[void](Path @(46, 47, 52, 47))
[void](Box 52 42 32 10 $ST.COMPUTE ("寄存 4 级 + 64 点滑窗求和 → E") $false 6.5)
# fifo
[void](Path @(18, 38, 22, 38, 22, 57, 90, 57))
[void](Box 90 52 18 10 $ST.STORE ("FIFO 128") $false 6.5)
# combine + decide
[void](Path @(108, 21, 114, 21))
[void](Path @(84, 47, 111, 47, 111, 34, 114, 34))
[void](Path @(108, 57, 120, 57, 120, 40))
[void](Box 114 12 32 28 $ST.WEIGHT ("对齐三路（axis_combine）`n判决：|X|² > E/4 + E/8`n且 E > 2500`n`n状态机 IDLE → DATA`n放行 2×64 + 683×80 个采样") $false 6.5)
[void](Line 146 26 152 26)
[void](Box 152 20 18 12 $ST.STORE ("去 CP`n→ FFT") $false 6.5)
[void](Label 124 44 54 18 ("FIR 系数为 LTF 匹配滤波器循环移位 9 个抽头，使 FFT 窗口落在 CP 内 8 个采样处。三个 FIR 共用一个 FIR Compiler 配置（3 组系数）。") 6.5 0 $ST.MUTE)
Save-Figure (Join-Path $here 'sync_hw_ts.vsdx') (Join-Path $repo 'report\figures\hw\ts_hw.png')
'saved'
