# fig06: sharing the input of parallel branches (RU, projection RG/RB, ATT).
#   powershell -ExecutionPolicy Bypass -File fig06_branch_reuse.ps1   -> fig06_branch_reuse.vsdx + ../network/fig06_branch_reuse.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$X = [char]0x00D7

Open-Visio 180 156

# ---------------------------------------------------------------- (a) RU
$o = 0
[void](Label 2 ($o + 2) 176 6 '(a) RU（上采样残差块）：主路、旁路的首个卷积读同一个窗口，合并为一个引擎' 10 0 $ST.INK $true)
[void](Box 4 ($o + 18) 22 14 $ST.STORE ([string]"3" + $X + "3 窗口"))
[void](Line 26 ($o + 25) 32 ($o + 25))
[void](Box 32 ($o + 18) 34 14 $ST.COMPUTE ([string]"合并 3" + $X + "3 卷积`n输出 2" + $X + "Cout" + $X + "r" + [char]0x00B2 + " 通道"))
[void](Line 66 ($o + 25) 72 ($o + 25) $false); [void](Dot 72 ($o + 25))
[void](Path @(72, ($o + 25), 72, ($o + 16), 80, ($o + 16)))
[void](Path @(72, ($o + 25), 72, ($o + 34), 80, ($o + 34)))
[void](Box 80 ($o + 10) 24 12 $ST.COMPUTE ([string]"像素重排 " + $X + "r"))
[void](Line 104 ($o + 16) 110 ($o + 16))
[void](Box 110 ($o + 10) 30 12 $ST.COMPUTE ([string]"3" + $X + "3 卷积 + IGDN"))
[void](Box 80 ($o + 28) 24 12 $ST.COMPUTE ([string]"像素重排 " + $X + "r"))
[void](Line 104 ($o + 34) 110 ($o + 34))
[void](Box 110 ($o + 28) 30 12 $ST.STORE '对齐 FIFO')
[void](Circle 156 ($o + 25) 3.5 '+')
[void](Path @(140, ($o + 16), 156, ($o + 16), 156, ($o + 21.5)))
[void](Path @(140, ($o + 34), 156, ($o + 34), 156, ($o + 28.5)))
[void](Line 159.5 ($o + 25) 170 ($o + 25)); [void](Label 170.5 ($o + 22.5) 9 5 '输出' 8.5 0)
[void](Label 4 ($o + 42) 172 5 ([string]'主路、旁路各 Cout' + $X + 'r' + [char]0x00B2 + ' 个通道，主路的激活融合在卷积引擎中。合并后两条支路共用一次窗口读取，少一个卷积引擎。') 8.5 0 $ST.MUTE)

# ---------------------------------------------------------------- (b) RG / RB with projection skip
$o = 52
[void](Label 2 ($o + 2) 176 6 '(b) 带投影旁路的 RG / RB：旁路直接取主路窗口的中心抽头' 10 0 $ST.INK $true)
[void](Box 4 ($o + 18) 22 14 $ST.STORE ([string]"3" + $X + "3 窗口"))
[void](Line 26 ($o + 25) 30 ($o + 25) $false); [void](Dot 30 ($o + 25))
[void](Path @(30, ($o + 25), 30, ($o + 16), 36, ($o + 16)))
[void](Path @(30, ($o + 25), 30, ($o + 34), 36, ($o + 34)))
[void](Box 36 ($o + 10) 104 12 $ST.COMPUTE ([string]"主路：3" + $X + "3 卷积 " + [char]0x2192 + " 激活 " + [char]0x2192 + " 3" + $X + "3 卷积 " + [char]0x2192 + " GDN（RG）/ 激活（RB）"))
[void](Box 36 ($o + 28) 26 12 $ST.COMPUTE '中心抽头')
[void](Line 62 ($o + 34) 70 ($o + 34))
[void](Box 70 ($o + 28) 32 12 $ST.COMPUTE ([string]"旁路 1" + $X + "1 卷积"))
[void](Line 102 ($o + 34) 110 ($o + 34))
[void](Box 110 ($o + 28) 30 12 $ST.STORE '延迟对齐 FIFO')
[void](Circle 156 ($o + 25) 3.5 '+')
[void](Path @(140, ($o + 16), 156, ($o + 16), 156, ($o + 21.5)))
[void](Path @(140, ($o + 34), 156, ($o + 34), 156, ($o + 28.5)))
[void](Line 159.5 ($o + 25) 170 ($o + 25)); [void](Label 170.5 ($o + 22.5) 9 5 '输出' 8.5 0)
[void](Label 4 ($o + 42) 172 5 '中心抽头即窗口中心的像素（随主路步长取样），旁路不再单独缓存和读取输入；主路、旁路由延迟 FIFO 对齐后相加。' 8.5 0 $ST.MUTE)

# ---------------------------------------------------------------- (c) ATT
$o = 104
[void](Label 2 ($o + 2) 176 6 ('(c) ATT（注意力块）：两个分支的首个 1' + $X + '1 卷积读同一输入，合并为一个引擎') 10 0 $ST.INK $true)
[void](Box 4 ($o + 19) 18 12 $ST.STORE '输入 x')
[void](Line 22 ($o + 25) 26 ($o + 25) $false); [void](Dot 26 ($o + 25))
[void](Line 26 ($o + 25) 30 ($o + 25))
[void](Box 30 ($o + 19) 34 12 $ST.COMPUTE ([string]"合并 1" + $X + "1 卷积`nA" + [char]0x2080 + " " + [char]0x2016 + " B" + [char]0x2080))
[void](Line 64 ($o + 25) 68 ($o + 25) $false); [void](Dot 68 ($o + 25))
[void](Path @(68, ($o + 25), 68, ($o + 16), 74, ($o + 16)))
[void](Path @(68, ($o + 25), 68, ($o + 34), 74, ($o + 34)))
[void](Box 74 ($o + 11) 40 10 $ST.COMPUTE 'A 支路其余算子 ' )
[void](Box 74 ($o + 29) 40 10 $ST.COMPUTE 'B 支路其余算子')
[void](Line 114 ($o + 34) 118 ($o + 34))
[void](Box 118 ($o + 29) 16 10 $ST.OPTION 'sigmoid')
[void](Circle 142 ($o + 25) 3.5 ([string][char]0x2299) 11)
[void](Path @(114, ($o + 16), 142, ($o + 16), 142, ($o + 21.5)))
[void](Path @(134, ($o + 34), 142, ($o + 34), 142, ($o + 28.5)))
[void](Line 145.5 ($o + 25) 152.5 ($o + 25))
[void](Circle 156 ($o + 25) 3.5 '+')
[void](Path @(26, ($o + 25), 26, ($o + 9), 156, ($o + 9), 156, ($o + 21.5)))
[void](Line 159.5 ($o + 25) 170 ($o + 25)); [void](Label 170.5 ($o + 22.5) 9 5 '输出' 8.5 0)
[void](Label 112 ($o + 22.5) 24 5 ([string]'y = x + a ' + [char]0x2299 + ' ' + [char]0x03C3 + '(b)') 8 1)
[void](Label 4 ($o + 42) 172 5 '两个分支各由 3 个残差单元组成，各自的第一个 1×1 卷积读同一个输入 x：合并后共用一次输入读取，输出按通道拆给两个分支。' 8.5 0 $ST.MUTE)

Save-Figure (Join-Path $here 'fig06_branch_reuse.vsdx') (Join-Path $repo 'report\figures\network\fig06_branch_reuse.png')
'saved'
