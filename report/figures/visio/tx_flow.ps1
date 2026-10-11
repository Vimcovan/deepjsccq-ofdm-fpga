# TX main program (tx_camera.py) and the JPEG quality search (sscc_pkt.JpegFit).
#   powershell -ExecutionPolicy Bypass -File tx_flow.ps1   -> tx_flow.vsdx + ../sw/tx_flow.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$ST.SIZE = 7

Open-Visio 180 160

# ---------------------------------------------------------------- (a) main program
[void](Label 2 1 110 6 '(a) TX 主程序 tx_camera.py' 9 0 $ST.INK $true)
$cx = 50; $w = 60; $x = $cx - $w / 2
[void](Terminal $x 9 $w 7 $ST.GRAY 'systemd 启动 jscc-tx.service')
[void](Line $cx 16 $cx 20)
[void](Box $x 20 $w 10 $ST.COMPUTE ("加载比特流 JsccTx()，切到 PRBS 源`n统计 1 s 内发往 DAC 的帧数 r"))
[void](Line $cx 30 $cx 33)
[void](Diamond $cx 39 34 12 $ST.WEIGHT 'r > 300 帧/s ?')
[void](Path @(($cx - 17), 39, 14, 39, 14, 25, $x, 25))
[void](Label 15 33 14 5 '否，重载' 6.5 0 $ST.MUTE)
[void](Line $cx 45 $cx 49); [void](Label ($cx + 1) 44.5 8 4.5 '是' 6.5 0 $ST.MUTE)
[void](Box $x 49 $w 10 $ST.COMPUTE ("切回编码器，读 TX 衰减；启动线程：`n三个数据源、控制、衰减、预览"))
[void](Line $cx 59 $cx 63)
[void](Box $x 63 $w 9 $ST.COMPUTE ("从当前数据源取序号更新的一帧`n图像 img（256×256×3）"))
[void](Line $cx 72 $cx 75)
[void](Diamond $cx 81 40 12 $ST.WEIGHT 'GUI 要求切换模式？')
[void](Path @(($cx + 20), 81, ($cx + 36), 81, ($cx + 36), 89))
[void](Box ($cx + 22) 89 28 12 $ST.COMPUTE ("切到 SSCC 前等 60 ms`n写控制寄存器的模式位`nPL 在帧边界切换") $false 6.5)
[void](Path @(($cx + 36), 101, ($cx + 36), 105, $cx, 105))
[void](Label ($cx + 21) 76 12 4.5 '是' 6.5 0 $ST.MUTE)
[void](Line $cx 87 $cx 98); [void](Label ($cx + 1) 87.5 8 4.5 '否' 6.5 0 $ST.MUTE)
[void](Diamond $cx 104 30 12 $ST.WEIGHT 'SSCC 模式？')
[void](Path @(($cx - 15), 104, ($cx - 34), 104, ($cx - 34), 112))
[void](Label ($cx - 30) 99 10 4.5 '是' 6.5 0 $ST.MUTE)
[void](Box ($cx - 46) 112 25 13 $ST.OPTION ("JPEG 自适应压缩`n打包（12272 B）`n送图像 DMA") $false 6.5)
[void](Line $cx 110 $cx 114); [void](Label ($cx + 1) 109.5 8 4.5 '否' 6.5 0 $ST.MUTE)
[void](Box ($cx - 16) 114 32 11 $ST.COMPUTE ("send_image(img)`nMM2S 196608 B，受编码器`n反压，收完才返回") $false 6.5)
[void](Path @(($cx - 33.5), 125, ($cx - 33.5), 130, $cx, 130))
[void](Line $cx 125 $cx 133)
[void](Box $x 133 $w 9 $ST.COMPUTE ("预览：帧号与采集时间戳立即发，`n原图交给预览线程（只留最新一帧）") $false 6.5)
[void](Path @(($cx + 30), 137.5, ($cx + 56), 137.5, ($cx + 56), 67.5, ($cx + 30), 67.5))
[void](Label ($cx + 45) 116 10 9 ("下一帧") 6.5 1 $ST.MUTE)

# ---------------------------------------------------------------- (b) JPEG quality search
[void](Label 112 1 68 6 '(b) JpegFit：JPEG 质量自适应' 9 0 $ST.INK $true)
$cx = 146; $w = 52; $x = $cx - $w / 2
[void](Terminal $x 9 $w 7 $ST.GRAY 'q ← 上一帧的质量因子')
[void](Line $cx 16 $cx 20)
[void](Box $x 20 $w 8 $ST.COMPUTE 'buf = imencode(img, q)')
[void](Line $cx 28 $cx 31)
[void](Diamond $cx 38 44 14 $ST.WEIGHT ("len(buf) ≤ 12260`n或 q ≤ 5 ?"))
[void](Path @(($cx + 22), 38, ($cx + 30), 38, ($cx + 30), 24, ($cx + 26), 24))
[void](Label ($cx + 14) 29 12 5 'q ← q − 5' 6.5 2 $ST.MUTE)
[void](Line $cx 45 $cx 50); [void](Label ($cx + 1) 45 8 4.5 '是' 6.5 0 $ST.MUTE)
[void](Diamond $cx 57 44 14 $ST.WEIGHT ("q 未下调过`n且 q < 95 ?"))
[void](Line $cx 64 $cx 69); [void](Label ($cx + 1) 64 8 4.5 '是' 6.5 0 $ST.MUTE)
[void](Box $x 69 $w 10 $ST.COMPUTE ("试 q + 5：放得下就采用"))
[void](Path @(($cx - 22), 57, ($cx - 30), 57, ($cx - 30), 84, $cx, 84))
[void](Label ($cx - 30) 52 10 4.5 '否' 6.5 1 $ST.MUTE)
[void](Line $cx 79 $cx 86)
[void](Terminal $x 86 $w 8 $ST.GREEN ("记下 q，返回 (JPEG, q)"))
[void](Label 116 98 62 30 ("包格式（12272 字节）：`n魔数 'SC'、帧号、JPEG 长度、`n质量因子、CRC32（12 字节），`nJPEG 数据，其余补零。`n`n每帧 q 最多变化一档，又能跟上`n画面复杂度的变化。") 7 0 $ST.INK)

Save-Figure (Join-Path $here 'tx_flow.vsdx') (Join-Path $repo 'report\figures\sw\tx_flow.png')
'saved'
