# PC tool chain: training -> integer model -> RTL -> simulation -> bitstream -> measurement.
#   powershell -ExecutionPolicy Bypass -File pc_toolchain.ps1   -> pc_toolchain.vsdx + ../sw/pc_toolchain.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$ST.SIZE = 7

Open-Visio 180 84

function Step($x, $y, $w, $title, $body, $fill = $ST.COMPUTE, $h = 16) { [void](Box $x $y $w $h $fill ("$title`n$body") $false 6.5) }
function File($x, $y, $w, $txt) { [void](Box $x $y $w 9 $ST.WEIGHT $txt $false 6.5) }

# row 1: model
[void](Label 2 1 80 5 'src/model（Python + PyTorch）' 8 0 $ST.INK $true)
Step 2 8 26 'prepare_cache.py' ("DIV2K + Flickr2K`n→ uint8 .npy 缓存")
[void](Line 28 16 32 16)
Step 32 8 30 'train_v2.py' ("AWGN 10 dB，MSE + 0.05 KL`n硬量化前向 / 软量化反向`n1200 轮")
[void](Line 62 16 66 16)
File 66 11.5 18 'best.pt'
[void](Line 84 16 88 16)
Step 88 8 36 'export_fpga.py + int_ref.py' ("W8A12 训练后量化`n整数算法：rsr、sat、GDN、sigmoid")
[void](Line 124 16 128 16)
File 128 7 50 'manifest.json（结构、张量、量化参数）'
File 128 18 50 'params/*.mem、golden/ 黄金张量'

# row 2: RTL
[void](Label 2 29.5 80 5 'src/network（顶层例化与参数文件）' 8 0 $ST.INK $true)
[void](Path @(153, 27, 153, 35.5, 14, 35.5, 14, 38))
Step 2 38 26 'memory_plan.py' ("并行度 P、ROM 方式`n缓存原语、URAM 迁移")
[void](Line 28 46 32 46)
Step 32 38 30 'gen_rtl_init.py' ("权重 / 偏置 / M / sh`n→ rtl_init/*.mem")
[void](Line 62 46 66 46)
Step 66 38 30 'gen_rtl_top.py' ("例化手写模块、传参、连线`n→ blk_enc_*.sv`n   blk_rx_*.sv")
[void](Line 96 46 100 46)
File 100 41.5 40 'blk_*.sv + rtl_init/*.mem → src/hw'

# row 3: build + measure
[void](Label 2 58.5 80 5 'build + board/tests' 8 0 $ST.INK $true)
[void](Path @(83, 54, 83, 64.5, 14, 64.5, 14, 67))
Step 2 67 30 'build/build_hw.tcl' ("Vivado 2025.2，默认策略`nfiles.txt → 工程、IP、PS BD")
[void](Line 32 75 36 75)
File 36 70.5 26 'jscc_tx/rx.bit + .hwh'
[void](Line 62 75 66 75)
Step 66 67 34 'board/tests（板上）' ("measure_link.py：衰减扫描`npl_events.py：PL 帧计数器") $ST.GREEN
[void](Line 100 75 104 75)
Step 104 67 34 'PC 分析' ("analyze_const.py：数据辅助 SNR`nseg_latency.py：分段时延`nplot_*.m：出图")
[void](Line 138 75 142 75)
File 142 70.5 36 'data/measurements（第三部分）'

Save-Figure (Join-Path $here 'pc_toolchain.vsdx') (Join-Path $repo 'report\figures\sw\pc_toolchain.png')
'saved'
