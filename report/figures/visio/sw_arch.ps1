# Board software: processes / threads on the TX and RX PS and the PL interfaces they use.
#   powershell -ExecutionPolicy Bypass -File sw_arch.ps1   -> sw_arch.vsdx + ../sw/sw_arch.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$ST.SIZE = 7

Open-Visio 180 124

# ---------------------------------------------------------------- TX board
[void](Box 2 4 64 110 $null '' $false 8 '0.75 pt')
[void](Label 4 5 60 5 'TX 板 PS（PYNQ 3.1，Python 3）' 8 0 $ST.INK $true)
[void](Box 6 13 56 46 $ST.GREEN '' $false)
[void](Label 8 14 52 5 'jscc-tx.service → tx_camera.py' 7.5 0 $ST.INK $true)
[void](Box 9 21 23.5 9 $ST.COMPUTE ("数据源线程`n摄像头 / 视频 / 静态图") $false 6.5)
[void](Box 35.5 21 23.5 9 $ST.COMPUTE ("主循环`n取帧 → 送图") $false 6.5)
[void](Box 9 33 23.5 9 $ST.COMPUTE ("控制线程`n信源 / 模式 / 衰减命令") $false 6.5)
[void](Box 35.5 33 23.5 9 $ST.COMPUTE ("衰减线程`n衰减斜坡") $false 6.5)
[void](Box 9 45 50 9 $ST.COMPUTE ("预览线程：预览帧 + 时间戳（只留最新一帧）") $false 6.5)
$a = Line 32.5 25.5 35.5 25.5; $a.CellsU('EndArrowSize').FormulaU = '0'
[void](Box 6 63 56 14 $ST.STORE ("jscc_tx.py（Overlay / MMIO / DMA / SPI）`nsscc_pkt.py（包格式、JpegFit）`nv4l2ctl.py（UVC ioctl）") $false 6.5)
[void](Line 34 59 34 63)
[void](Box 6 83 27 14 $ST.WEIGHT ("图像 DMA`nMM2S`n0x8000_0000") $false 6.5)
[void](Box 35 83 27 14 $ST.WEIGHT ("TX 控制寄存器组`nAXI4-Lite`n0x8002_0000") $false 6.5)
[void](Line 19.5 77 19.5 83); [void](Line 48.5 77 48.5 83)
[void](Label 6 99 56 12 ("PL：编码器 / SSCC / OFDM 发射 / AD9361`nUSB 摄像头 → /dev/video0") 6.5 1 $ST.MUTE)

# ---------------------------------------------------------------- RX board
[void](Box 74 4 104 110 $null '' $false 8 '0.75 pt')
[void](Label 76 5 100 5 'RX 板 PS' 8 0 $ST.INK $true)
# rx_server
[void](Box 78 13 46 64 $ST.GREEN '' $false)
[void](Label 80 14 42 5 'jscc-rx.service → rx_server.py' 7.5 0 $ST.INK $true)
$th = @('图像接收：图像 DMA，双缓冲', '图像发送：UDP 图像消息', '遥测：10 Hz', '频谱：ADC 抓取 → 频谱 2 Hz', 'SSCC 包转发', 'AGC 记录：失步时记录（只读）', 'AGC 看门狗')
for ($k = 0; $k -lt $th.Count; $k++) { [void](Box 80 (21 + $k * 7.6) 42 6.4 $ST.COMPUTE $th[$k] $false 6.5) }
[void](Box 78 81 46 12 $ST.STORE ("jscc_rx.py（Overlay / DMA 复位 / 遥测）`nad9361_ps.py（PS 初始化、AGC 看门狗）") $false 6.5)
[void](Line 101 77 101 81)
[void](Box 78 97 22 14 $ST.WEIGHT ("图像 DMA`nADC 抓取 DMA`n（S2MM）") $false 6.5)
[void](Box 102 97 22 14 $ST.WEIGHT ("RX 控制寄存器组`n遥测接口") $false 6.5)
[void](Line 89 93 89 97); [void](Line 113 93 113 97)
# GUI
[void](Box 128 13 46 52 $ST.GREEN '' $false)
[void](Label 130 14 42 5 'jscc-gui.service → jscc_gui.py' 7.5 0 $ST.INK $true)
[void](Box 130 21 42 7 $ST.COMPUTE '网络接收子进程：分片重组' $false 6.5)
[void](Box 130 30 42 7 $ST.COMPUTE 'Qt 主线程：页面、PSNR 配对、控制' $false 6.5)
[void](Box 130 39 42 7 $ST.COMPUTE '触摸手势：evdev 长按 / 拖动' $false 6.5)
[void](Box 130 48 42 7 $ST.COMPUTE '三维渲染线程：向子进程发请求' $false 6.5)
[void](Box 130 71 42 12 $ST.OPTION ("h3d_render.py 子进程`nGBM + EGL + GLES2（离屏）") $false 6.5)
[void](Line 151 55 151 71)
[void](Box 130 89 42 9 $ST.WEIGHT 'Mali-400 MP2（lima）' $false 6.5)
[void](Line 151 83 151 89)
[void](Label 128 101 48 10 ("X 服务（armsoc，2D）→ DisplayPort`n触摸屏 1024×600") 6.5 1 $ST.MUTE)

# ---------------------------------------------------------------- UDP links
[void](Path @(124, 24.5, 130, 24.5))
$eth = Path @(62, 49.5, 70, 49.5, 70, 118, 177, 118, 177, 39, 174, 39) $true $true
$eth.CellsU('BeginArrow').FormulaU = '4'; $eth.CellsU('BeginArrowSize').FormulaU = '0'; $eth.CellsU('EndArrowSize').FormulaU = '0'
[void](Label 72 118.5 104 5 '以太网 UDP：TX 预览帧与时间戳 → GUI；GUI → TX：信源 / 模式 / 衰减命令（双向）' 6.5 0 $ST.MUTE)

Save-Figure (Join-Path $here 'sw_arch.vsdx') (Join-Path $repo 'report\figures\sw\sw_arch.png')
'saved'
