# fig07: per-layer parallelism, weight ROM mapping, activation storage (data from data/model/manifest.json).
#   powershell -ExecutionPolicy Bypass -File fig07_memory.ps1   -> fig07_memory.vsdx + ../network/fig07_memory.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$plan = (Get-Content (Join-Path $repo 'data\model\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).memory_plan

# ---------------------------------------------------------------- data
$D = @{}
foreach ($side in 'encoder', 'decoder') {
  $all = $plan.$side.engines
  $conv = @($all | Where-Object { "$($_.note)" -notmatch 'GDN' })
  $pmax = ($conv | Measure-Object P -Maximum).Maximum
  $buf = $plan.$side.buffers
  $D[$side] = @{
    P = @($conv | ForEach-Object { [int]$_.P })
    U = @($conv | ForEach-Object { [math]::Min($pmax, [int]$_.cout) })
    Pmax = $pmax
    modes = @{ lut = @($conv | Where-Object mode -eq 'lut').Count; direct = @($conv | Where-Object mode -eq 'direct').Count; gear = @($conv | Where-Object mode -eq 'gear').Count }
    W = (($all | Measure-Object b18 -Sum).Sum) / 2
    Aall = (($buf | Measure-Object b18 -Sum).Sum) / 2
    Abram = ((@($buf | Where-Object loc -eq 'BRAM') | Measure-Object b18 -Sum).Sum) / 2
    URAM = (@($buf | Where-Object loc -ne 'BRAM') | Measure-Object uram -Sum).Sum
  }
  $D[$side].sumP = ($D[$side].P | Measure-Object -Sum).Sum
  $D[$side].sumU = ($D[$side].U | Measure-Object -Sum).Sum
}
$E = $D.encoder; $Dd = $D.decoder
"enc: n=$($E.P.Count) sumP=$($E.sumP) sumU=$($E.sumU) W=$($E.W) A=$($E.Aall)->$($E.Abram) URAM=$($E.URAM) modes=$($E.modes.lut)/$($E.modes.direct)/$($E.modes.gear)"
"dec: n=$($Dd.P.Count) sumP=$($Dd.sumP) sumU=$($Dd.sumU) W=$($Dd.W) A=$($Dd.Aall)->$($Dd.Abram) URAM=$($Dd.URAM) modes=$($Dd.modes.lut)/$($Dd.modes.direct)/$($Dd.modes.gear)"

Open-Visio 180 176

# ---------------------------------------------------------------- (a) per-layer P
[void](Label 2 2 176 6 '(a) 按层选择输出通道并行度 P' 10 0 $ST.INK $true)
$x0 = 18; $plotW = 158; $plotH = 26; $scale = $plotH / 52.0
function Panel($y0, $d, $name) {
  $n = $d.P.Count; $pitch = $plotW / $n; $bw = $pitch * 0.62
  $base = $y0 + $plotH
  [void](Line $x0 $base ($x0 + $plotW) $base $false)
  [void](Line $x0 $base $x0 ($y0 - 1) $false)
  foreach ($t in 0, 16, 32, 48) {
    $yt = $base - $t * $scale
    [void](Line ($x0 - 1.2) $yt $x0 $yt $false)
    [void](Label ($x0 - 9) ($yt - 2) 7.5 4 "$t" 8 2)
  }
  for ($k = 0; $k -lt $n; $k++) {
    $xb = $x0 + $k * $pitch + ($pitch - $bw) / 2
    $hu = $d.U[$k] * $scale; $hp = $d.P[$k] * $scale
    [void](Box $xb ($base - $hu) $bw $hu $null '' $true 9 '0.5 pt')
    [void](Box $xb ($base - $hp) $bw $hp $ST.STORE '' $false 9 '0.5 pt')
  }
  [void](Label ($x0 + 2) ($y0 - 6.5) 60 5 $name 9 0 $ST.INK $true)
  [void](Label ($x0 + 50) ($y0 - 6.5) ($plotW - 50) 5 ("实际 " + [char]0x03A3 + "P = $($d.sumP)，统一并行度时 $($d.sumU)") 9 2)
}
Panel 15 $E '编码器（53 个卷积引擎）'
Panel 50 $Dd '解码器（53 个卷积引擎）'
[void](Label 2 64 8 6 'P' 9 1 $ST.INK $false)
[void](Label $x0 77 $plotW 5 '卷积引擎（按数据流顺序，GDN 引擎不计）' 9 1)
# legend
[void](Box ($x0 + 2) 84 4 3 $ST.STORE '' $false 9 '0.5 pt')
[void](Label ($x0 + 7.5) 83 70 5 '按层选择的 P（满足 30 fps 的最小值）' 8.5 0)
[void](Box ($x0 + 80) 84 4 3 $null '' $true 9 '0.5 pt')
[void](Label ($x0 + 85.5) 83 72 5 ('统一并行度参考：min(P' + [char]0x2098 + [char]0x2090 + [char]0x2093 + '，Cout)') 8.5 0)

# ---------------------------------------------------------------- (b) weight ROM mapping
$yb = 94
[void](Label 2 $yb 88 6 '(b) 权重 ROM 的三种映射' 10 0 $ST.INK $true)
function Out-Arrow($x, $y) { [void](Line $x $y ($x + 9) $y); [void](Label ($x + 9.5) ($y - 2.5) 16 5 ([string]'P' + [char]0x00D7 + '8 bit') 8.5 0) }
# 1 LUT
$y = $yb + 9
[void](Label 4 $y 86 5 "小 ROM：分布式 LUT ROM（编码器 $($E.modes.lut) / 解码器 $($Dd.modes.lut) 个引擎）" 8.5 0)
[void](Box 8 ($y + 6) 30 10 $ST.WEIGHT 'LUT ROM')
Out-Arrow 38 ($y + 11)
# 2 direct
$y = $yb + 30
[void](Label 4 $y 86 5 "直接映射：并排的 BRAM36 列，每列 72 bit = 9 路（$($E.modes.direct) / $($Dd.modes.direct)）" 8.5 0)
for ($k = 0; $k -lt 3; $k++) { [void](Box (8 + $k * 10.5) ($y + 6) 9.5 10 $ST.WEIGHT ([string]'72' + "`n" + 'bit') $false 8) }
[void](Label 39 ($y + 8.5) 5 5 ([string][char]0x2026) 9 1)
Out-Arrow 45 ($y + 11)
# 3 gear
$y = $yb + 51
[void](Label 4 $y 86 5 "紧密打包：32 bit BRAM 列 + 字节位宽转换器（$($E.modes.gear) / $($Dd.modes.gear)）" 8.5 0)
[void](Box 8 ($y + 6) 22 10 $ST.WEIGHT ([string]"BRAM`n32 bit " + [char]0x00D7 + ' N 列') $false 8)
[void](Line 30 ($y + 11) 36 ($y + 11))
[void](Box 36 ($y + 6) 20 10 $ST.COMPUTE "位宽`n转换器" $false 8)
Out-Arrow 56 ($y + 11)

# ---------------------------------------------------------------- (c) activation storage
$xc = 98
[void](Label $xc $yb 80 6 '(c) 大激活缓存迁入 URAM（BRAM36 规划值）' 10 0 $ST.INK $true)
$cx0 = $xc + 12; $cbase = $yb + 66; $cs = 52.0 / 160
[void](Line $cx0 $cbase ($xc + 78) $cbase $false)
[void](Line $cx0 $cbase $cx0 ($yb + 11) $false)
foreach ($t in 0, 50, 100, 150) {
  $yt = $cbase - $t * $cs
  [void](Line ($cx0 - 1.2) $yt $cx0 $yt $false)
  [void](Label ($cx0 - 10) ($yt - 2) 8.5 4 "$t" 8 2)
}
$yb100 = $cbase - 100 * $cs
[void](Line $cx0 $yb100 ($xc + 78) $yb100 $false $true $ST.MUTE)
$bars = @(
  @(0, $E.W, $E.Aall, '迁移前', ''), @(1, $E.W, $E.Abram, '迁移后', "+$($E.URAM) URAM"),
  @(3, $Dd.W, $Dd.Aall, '迁移前', ''), @(4, $Dd.W, $Dd.Abram, '迁移后', "+$($Dd.URAM) URAM"))
foreach ($b in $bars) {
  $bx = $cx0 + 4 + $b[0] * 12.5; $bw = 9
  $hw = $b[1] * $cs; $ha = $b[2] * $cs
  [void](Box $bx ($cbase - $hw) $bw $hw $ST.WEIGHT '' $false 9 '0.5 pt')
  [void](Box $bx ($cbase - $hw - $ha) $bw $ha $ST.STORE '' $false 9 '0.5 pt')
  [void](Label ($bx - 3) ($cbase - $hw - $ha - 5) ($bw + 6) 4.5 ('{0:0.#}' -f ($b[1] + $b[2])) 8 1)
  if ($b[4]) { [void](Label ($bx - 4) ($cbase - $hw - $ha - 9.5) ($bw + 8) 4.5 $b[4] 7.5 1 $ST.MUTE) }
  [void](Label ($bx - 3) ($cbase + 0.5) ($bw + 6) 4.5 $b[3] 8 1)
}
[void](Label ($cx0 + 2) ($cbase + 5) 24 5 '编码器' 9 1)
[void](Label ($cx0 + 39.5) ($cbase + 5) 24 5 '解码器' 9 1)
[void](Box ($cx0 + 3) ($yb + 10) 3.5 3 $ST.WEIGHT '' $false 9 '0.5 pt'); [void](Label ($cx0 + 7.5) ($yb + 9) 24 5 '权重 ROM' 8 0)
[void](Box ($cx0 + 3) ($yb + 15) 3.5 3 $ST.STORE '' $false 9 '0.5 pt'); [void](Label ($cx0 + 7.5) ($yb + 14) 24 5 '激活缓存' 8 0)
[void](Line ($cx0 + 2.5) ($yb + 21.5) ($cx0 + 7) ($yb + 21.5) $false $true $ST.MUTE); [void](Label ($cx0 + 7.5) ($yb + 19) 34 5 '每核预算 100' 8 0)

Save-Figure (Join-Path $here 'fig07_memory.vsdx') (Join-Path $repo 'report\figures\network\fig07_memory.png')
'saved'
