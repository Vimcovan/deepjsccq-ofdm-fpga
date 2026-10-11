# AD9361 PS initialisation (AD9361.init) and the AGC watchdog (AgcGuard.check), ad9361_ps.py.
#   powershell -ExecutionPolicy Bypass -File agc_flow.ps1   -> agc_flow.vsdx + ../sw/agc_flow.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$ST.SIZE = 7

Open-Visio 180 128

# ---------------------------------------------------------------- (a) PS init
[void](Label 2 1 80 6 '(a) AD9361.init()' 9 0 $ST.INK $true)
$cx = 40; $w = 64; $x = $cx - $w / 2
[void](Terminal $x 9 $w 7 $ST.GRAY 'JsccRx() 加载比特流（VERSION ≥ 2）')
[void](Line $cx 16 $cx 19)
[void](Box $x 19 $w 8 $ST.COMPUTE 'RF_CTRL = 001：PS 模式，RESETB 低')
[void](Line $cx 27 $cx 30)
[void](Box $x 30 $w 8 $ST.COMPUTE '2 ms 后 RF_CTRL = 011：释放 RESETB')
[void](Line $cx 38 $cx 41)
[void](Box $x 41 $w 10 $ST.WEIGHT ("读 ad9361_rx_init.json 的操作列表`n（由 PL 的初始化 LUT 转换而来）"))
[void](Line $cx 51 $cx 54)
[void](Box $x 54 $w 22 $ST.COMPUTE ("逐条执行：`nw  addr val：SPI 写`nr  addr：SPI 读`ndelay ms：延时`npoll addr mask want：轮询，超时 2 s`n报错并指出第几条") $false 7)
[void](Line $cx 76 $cx 79)
[void](Box $x 79 $w 10 $ST.COMPUTE ("RF_CTRL = 111：初始化完成`nPL 释放 FIFO，ENABLE / TXNRX 拉高"))
[void](Line $cx 89 $cx 92)
[void](Terminal $x 92 $w 7 $ST.GREEN '打印操作数、耗时与 ENSM 状态')
[void](Label 4 104 78 20 ("每次 SPI 传输：写 SPI_CMD（地址、数据、读 / 写位），`n等 SPI_STAT[15:8] 的传输计数加一（跨 20 MHz 域），`n再读 SPI_STAT[7:0] 得到读出数据。") 7 0 $ST.MUTE)

# ---------------------------------------------------------------- (b) AGC guard
[void](Label 92 1 88 6 '(b) AgcGuard.check()，每 0.5 s 一次' 9 0 $ST.INK $true)
$cx = 134; $w = 70; $x = $cx - $w / 2
[void](Box $x 9 $w 10 $ST.COMPUTE ("MMIO 读 SYNC_CNT 与增益索引 g`n（PL 寄存器，不经过 SPI）"))
[void](Line $cx 19 $cx 22)
[void](Box $x 22 $w 10 $ST.COMPUTE ("历史队列中保留至少 0.5 s 前的一个样点`nrate = ΔSYNC_CNT / Δt"))
[void](Line $cx 32 $cx 35)
[void](Diamond $cx 42 50 14 $ST.WEIGHT ("跨度 ≥ 0.5 s 且`nrate < 5 帧/s ？"))
[void](Line $cx 49 $cx 54); [void](Label ($cx + 1) 49 8 4.5 '是' 6.5 0 $ST.MUTE)
[void](Diamond $cx 61 50 14 $ST.WEIGHT ("g < 增益表上限 gmax`n（0x0FD）？"))
[void](Line $cx 68 $cx 73); [void](Label ($cx + 1) 68 8 4.5 '是' 6.5 0 $ST.MUTE)
[void](Diamond $cx 80 50 14 $ST.WEIGHT ("距上次复位 > 3 s ？"))
[void](Line $cx 87 $cx 92); [void](Label ($cx + 1) 87 8 4.5 '是' 6.5 0 $ST.MUTE)
[void](Box $x 92 $w 10 $ST.OPTION ("加锁，SPI：0x0FA ← 0x05，再 ← 0xE5`n复位快速 AGC 状态机，计数并记日志"))
[void](Path @(($cx + 25), 42, ($cx + 42), 42, ($cx + 42), 108, $cx, 108))
[void](Path @(($cx + 25), 61, ($cx + 42), 61) $false)
[void](Path @(($cx + 25), 80, ($cx + 42), 80) $false)
[void](Label ($cx + 27) 37 12 4.5 '否' 6.5 0 $ST.MUTE)
[void](Line $cx 102 $cx 105)
[void](Terminal $x 105 $w 7 $ST.GREEN '返回 {gain, sync_rate, stalled, reset}')
[void](Label 96 115 84 12 ("判据只用同步率与增益是否到顶；`n只读 PL 计数器，不与基带耦合。") 7 0 $ST.MUTE)

Save-Figure (Join-Path $here 'agc_flow.vsdx') (Join-Path $repo 'report\figures\sw\agc_flow.png')
'saved'
