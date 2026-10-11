# System overview: TX board (top, left -> right) and RX board (bottom, right -> left), PS / PL / AD9361.
#   powershell -ExecutionPolicy Bypass -File sys_overview.ps1   -> sys_overview.vsdx + ../hw/sys_overview.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$X = [char]0x00D7
$AR = [char]0x2192

Open-Visio 180 132

# ------------------------------------------------------------------ TX board
[void](Box 2 4 176 58 $null '' $false 9 '0.75 pt')
[void](Label 4 5 130 5 'TX 板：PYNQ-ZU（xczu5eg）+ AD-FMCOMMS3（AD9361）' 9 0 $ST.INK $true)
[void](Box 33 11 120 49 $null '' $true 9 '0.5 pt')
[void](Label 34 11.5 40 4.5 'PL' 8.5 0 $ST.MUTE $true)
[void](Label 54 11.5 48 4.5 '250 MHz' 8 1 $ST.MUTE)
[void](Label 104 11.5 34 4.5 '100 MHz' 8 1 $ST.MUTE)
[void](Label 138 11.5 15 4.5 'data_clk' 8 1 $ST.MUTE)

[void](Box 4 16 26 36 $ST.GREEN ([string]"PS（A53）`n`n取图：摄像头、`n视频或预设图`n裁剪 256" + $X + "256`nJPEG 编码`n（SSCC 模式）`nAXI DMA") $false 7.5)
[void](Box 36 21 14 14 $ST.STORE ("32→8 位`n拆分`n+ CDC") $false 8)
[void](Box 54 19 28 18 $ST.COMPUTE ([string]"DeepJSCC-Q 编码器`n53 个卷积引擎`nW8A12") $false 8)
[void](Box 86 21 16 14 $ST.COMPUTE ("64QAM`n量化`nI/Q 配对") $false 8)
[void](Box 54 41 48 11 $ST.OPTION ("SSCC 基线：扰码 + K=7 卷积码`n+ 交织 + 64QAM 映射") $true 8)
[void](Box 106 21 13 31 $ST.STORE ("CDC`n`n按帧边界`n选择`nJSCC /`nSSCC /`nPRBS") $false 8)
[void](Box 123 19 14 18 $ST.COMPUTE ("OFDM`n发射") $false 8)
[void](Box 123 41 14 11 $ST.STORE ("URAM`n帧缓存") $false 8)
[void](Box 140 27 11 18 $ST.STORE ("LVDS`n1R1T`nDDR") $false 8)
[void](Box 156 27 16 18 $ST.WEIGHT ("AD9361`n`nDAC`n上变频") $false 8)

# TX data flow
[void](Line 30 28 36 28)
[void](Line 50 28 54 28)
[void](Line 82 28 86 28)
[void](Line 102 28 106 28)
[void](Path @(30, 46.5, 54, 46.5))
[void](Line 102 46.5 106 46.5)
[void](Line 119 28 123 28)
[void](Line 130 37 130 41)
[void](Path @(137, 46.5, 145.5, 46.5, 145.5, 45))
[void](Line 151 36 156 36)
[void](Label 30 22.5 7 4 '图像' 7 1 $ST.MUTE)
[void](Label 31 42 22 4 'JPEG 包' 7 0 $ST.MUTE)

# TX antenna
[void](Line 172 36 175 36 $false)
[void](Path @(175, 36, 175, 30) $false)
[void](Path @(172.5, 27, 175, 30, 177.5, 27) $false)

# ------------------------------------------------------------------ RX board
$o = 68
[void](Box 2 $o 176 60 $null '' $false 9 '0.75 pt')
[void](Label 36 ($o + 1) 130 5 'RX 板：PYNQ-ZU（xczu5eg）+ AD-FMCOMMS3（AD9361）' 9 0 $ST.INK $true)
[void](Box 33 ($o + 7) 120 51 $null '' $true 9 '0.5 pt')
[void](Label 34 ($o + 7.5) 40 4.5 'PL' 8.5 0 $ST.MUTE $true)
[void](Label 36 ($o + 7.5) 48 4.5 '250 MHz' 8 2 $ST.MUTE)
[void](Label 90 ($o + 7.5) 46 4.5 '100 MHz' 8 1 $ST.MUTE)
[void](Label 138 ($o + 7.5) 15 4.5 'data_clk' 8 1 $ST.MUTE)

[void](Box 156 ($o + 15) 16 18 $ST.WEIGHT ("AD9361`n`n下变频`nADC`n快速 AGC") $false 8)
[void](Box 140 ($o + 15) 11 18 $ST.STORE ("LVDS`n1R1T`nDDR") $false 8)
[void](Box 113 ($o + 13) 23 22 $ST.COMPUTE ("OFDM 接收`n帧检测、CFO`nLTF 定时`n信道估计`nSFO、CPE`nPN 解扰") $false 7.5)
[void](Box 96 ($o + 15) 13 18 $ST.STORE ("URAM`n帧缓存") $false 8)
[void](Box 85 ($o + 17) 8 14 $ST.STORE 'CDC' $false 8)
[void](Box 54 ($o + 15) 27 18 $ST.COMPUTE ([string]"DeepJSCC-Q 解码器`n53 个卷积引擎`n软符号输入") $false 8)
[void](Box 36 ($o + 17) 14 14 $ST.STORE ("8→32 位`n打包`n+ CDC") $false 8)
[void](Box 96 ($o + 39) 40 11 $ST.OPTION ("SSCC 基线：软解映射、解交织、`nViterbi、解扰，包存入 RAM") $true 7.5)
[void](Box 36 ($o + 39) 45 11 $ST.GRAY ("遥测：均衡快照、ADC 抓取、`n帧计数器、SPI 命令寄存器") $false 7.5)
[void](Box 4 ($o + 12) 26 42 $ST.GREEN ("PS（A53）`n`nAD9361 初始化`nAGC 看门狗`n图像、遥测服务`nJPEG 解码`n（SSCC 模式）`nGUI：Qt +`nMali-400 GPU`n→ 触摸屏") $false 7.5)

# RX data flow (right -> left)
[void](Line 156 ($o + 24) 151 ($o + 24))
[void](Line 140 ($o + 24) 136 ($o + 24))
[void](Line 113 ($o + 24) 109 ($o + 24))
[void](Line 96 ($o + 24) 93 ($o + 24))
[void](Line 85 ($o + 24) 81 ($o + 24))
[void](Line 54 ($o + 24) 50 ($o + 24))
[void](Line 36 ($o + 24) 30 ($o + 24))
[void](Path @(124.5, ($o + 35), 124.5, ($o + 39)))
[void](Path @(96, ($o + 44.5), 81, ($o + 44.5)) $true $true)
[void](Line 36 ($o + 44.5) 30 ($o + 44.5) $true $true)
[void](Label 30 ($o + 18.5) 7 4 '图像' 7 1 $ST.MUTE)
[void](Label 82 ($o + 40.5) 14 4 'SSCC 包' 7 1 $ST.MUTE)

# RX antenna
[void](Line 172 ($o + 24) 175 ($o + 24) $false)
[void](Path @(175, ($o + 24), 175, ($o + 18)) $false)
[void](Path @(172.5, ($o + 15), 175, ($o + 18), 177.5, ($o + 15)) $false)

# ------------------------------------------------------------------ links between the boards
[void](Path @(175, 24, 175, ($o + 13)) $true $true)
[void](Label 140 ($o - 5.5) 33 5 '915 MHz 空口' 8.5 2 $ST.INK $true)
[void](Path @(17, 52, 17, ($o + 12)) $false $true)
[void](Label 19 ($o - 5.5) 120 5 '以太网（仅 TX 预览图与控制命令，不承载编码载荷）' 8 0 $ST.MUTE)

Save-Figure (Join-Path $here 'sys_overview.vsdx') (Join-Path $repo 'report\figures\hw\sys_overview.png')
'saved'
