# AD9361 PS initialisation (AD9361.init) and the AGC watchdog (AgcGuard.check), ad9361_ps.py.
#   powershell -ExecutionPolicy Bypass -File agc_flow.ps1   -> agc_flow.vsdx + ../sw/agc_flow.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$ST.SIZE = 7

Open-Visio 180 138
function Yes($x, $y) { [void](Label $x $y 8 4.5 '是' 6.5 0 $ST.MUTE) }

# ---------------------------------------------------------------- (a) PS init
[void](Label 2 1 80 6 '(a) AD9361.init()' 9 0 $ST.INK $true)
$cx = 42
[void](FTerm $cx 9 7 'JsccRx() 加载比特流（比特流版本号 ≥ 2）')
[void](Line $cx 16 $cx 19)
[void](FProc $cx 19 8 '射频控制寄存器写 001：PS 控制，复位引脚 RESETB 拉低')
[void](Line $cx 27 $cx 30)
[void](FProc $cx 30 8 '2 ms 后写 011：释放 RESETB')
[void](Line $cx 38 $cx 41)
[void](FProc $cx 41 10 ("读 ad9361_rx_init.json 的操作列表`n（由 PL 的初始化 LUT 转换而来）") 'INIT')
[void](Line $cx 51 $cx 54)
[void](FProc $cx 54 22 ("逐条执行：`nw  addr val：SPI 写`nr  addr：SPI 读`ndelay ms：延时`npoll addr mask want：轮询，超时 2 s`n出错时报出第几条"))
[void](Line $cx 76 $cx 79)
[void](FProc $cx 79 10 ("写 111：初始化完成`nPL 释放 FIFO，收发控制引脚 ENABLE / TXNRX 拉高"))
[void](Line $cx 89 $cx 92)
[void](FTerm $cx 92 7 '打印操作数、耗时与 ENSM 状态')
[void](Label 4 106 80 20 ("每次 SPI 传输：向 SPI 命令寄存器写入地址、数据和读 / 写位，`n等 SPI 状态寄存器中的传输计数加一（跨 20 MHz 时钟域），`n再从状态寄存器读出数据。") 7 0 $ST.MUTE)

# ---------------------------------------------------------------- (b) AGC guard
[void](Label 92 1 88 6 '(b) AgcGuard.check()' 9 0 $ST.INK $true)
$cx = 134
[void](FTerm $cx 9 7 'RX 服务每 0.5 s 调用一次')
[void](Line $cx 16 $cx 20)
[void](FProc $cx 20 10 ("MMIO 读 PHY 同步帧计数 n 与增益索引 g`n（PL 寄存器，不经过 SPI）"))
[void](Line $cx 30 $cx 33)
[void](FProc $cx 33 10 ("历史队列中保留至少 0.5 s 前的一个样点`n同步率 = Δn / Δt"))
[void](Line $cx 43 $cx 46)
[void](FDec $cx 53 50 14 ("跨度 ≥ 0.5 s 且`n同步率 < 5 帧/s ？"))
[void](Line $cx 60 $cx 65); Yes ($cx + 1) 60
[void](FDec $cx 72 50 14 ("g < 增益表上限？`n（0x0FD：最大增益索引）"))
[void](Line $cx 79 $cx 84); Yes ($cx + 1) 79
[void](FDec $cx 91 50 14 '距上次复位 > 3 s ？')
[void](Line $cx 98 $cx 103); Yes ($cx + 1) 98
[void](FProc $cx 103 10 ("加锁，SPI：0x0FA（AGC 配置 1）← 0x05，再 ← 0xE5`n复位快速 AGC 状态机，计数并记日志") 'ALT')
[void](Line $cx 113 $cx 117)
$en = FTerm $cx 117 7 '返回增益、同步率、是否停滞、本次是否复位'
$xr = $cx + 42
[void](Path @(($cx + 25), 53, $xr, 53, $xr, 120.5, $en.R, 120.5))
[void](Path @(($cx + 25), 72, $xr, 72) $false)
[void](Path @(($cx + 25), 91, $xr, 91) $false)
[void](Label ($cx + 27) 48 12 4.5 '否' 6.5 0 $ST.MUTE)
[void](Label 96 127 84 10 '判据只用同步率与增益是否到顶；只读 PL 计数器，不与基带耦合。' 7 0 $ST.MUTE)

Save-Figure (Join-Path $here 'agc_flow.vsdx') (Join-Path $repo 'report\figures\sw\agc_flow.png')
'saved'
