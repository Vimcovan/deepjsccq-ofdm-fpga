# fig02: DeepJSCC-Q encoder / decoder block structure (tensor shapes from data/model/manifest.json).
#   powershell -ExecutionPolicy Bypass -File fig02_network.ps1   -> fig02_network.vsdx + ../network/fig02_network.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$tens = (Get-Content (Join-Path $repo 'data\model\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tensors
function Shape($name) { $s = $tens.$name.shape_hwc; return ('{0}' + [char]0x00B2 + [char]0x00D7 + '{1}') -f $s[0], $s[2] }

$enc = @(@('RG', 's=2'), @('RB', ''), @('RG', 's=2'), @('ATT', ''), @('RB', ''), @('RG', 's=1'), @('RB', ''), @('RG', 's=1'), @('ATT', ''))
$dec = @(@('ATT', ''), @('RB', ''), @('RU', 'r=1'), @('RB', ''), @('RU', 'r=1'), @('ATT', ''), @('RB', ''), @('RU', 'r=2'), @('RB', ''), @('RU', 'r=2'))
$X = [char]0x00D7

Open-Visio 180 112

function Row($blocks, $prefix, $y, $w, $gap) {
  $xs = @()
  for ($k = 0; $k -lt $blocks.Count; $k++) {
    $x = 4 + $k * ($w + $gap)
    $b = $blocks[$k]
    $resize = ($b[1] -eq 's=2' -or $b[1] -eq 'r=2')
    $txt = $(if ($b[1]) { "$($b[0])`n$($b[1])" } else { $b[0] })
    [void](Box $x $y $w 13 $(if ($resize) { $ST.STORE } else { $ST.COMPUTE }) $txt)
    [void](Label ($x - 3) ($y - 5) ($w + 6) 4.5 "$k" 8 1 $ST.MUTE)
    [void](Label ($x - 4) ($y + 14) ($w + 8) 4.5 (Shape "$prefix.$k.out") 8 1)
    if ($k -gt 0) { [void](Line ($x - $gap) ($y + 6.5) $x ($y + 6.5)) }
    $xs += $x
  }
  return ,$xs
}

# encoder
[void](Label 2 2 120 6 ('(a) 编码器：256' + [char]0x00B2 + $X + '3 图像 ' + [char]0x2192 + ' 64' + [char]0x00B2 + $X + '16 潜变量（55 个卷积）') 10 0 $ST.INK $true)
$we = 15.2; $ge = 4.3
$ex = Row $enc 'enc' 15 $we $ge
$eLast = $ex[$ex.Count - 1] + $we / 2

# channel row
$yc = 41
[void](Box 118 $yc 58 12 $ST.WEIGHT ([string]"64-QAM 量化，相邻通道配成 I/Q`n32,768 个符号 / 帧"))
[void](Box 70 $yc 38 12 $null "OFDM 物理层`n与无线信道")
[void](Box 4 $yc 56 12 $ST.COMPUTE ([string]"均衡后的连续 I/Q（软符号）`n64" + $X + "64" + $X + "16 个实数"))
[void](Path @($eLast, 32.5, $eLast, $yc))
[void](Line 118 ($yc + 6) 108 ($yc + 6))
[void](Line 70 ($yc + 6) 60 ($yc + 6))

# decoder
[void](Label 10 59 120 6 ('(b) 解码器：软符号 ' + [char]0x2192 + ' 256' + [char]0x00B2 + $X + '3 图像（59 个卷积）') 10 0 $ST.INK $true)
$wd = 13.4; $gd = 4.0
$dx = Row $dec 'dec' 72 $wd $gd
[void](Path @(($dx[0] + 2.5), ($yc + 12), ($dx[0] + 2.5), 72))
$dLast = $dx[$dx.Count - 1] + $wd
[void](Label ($dLast - 50) 91 50 4.5 ('sigmoid ' + [char]0x2192 + ' 8 位 RGB 输出') 8.5 2)

# legend
$yl = 99
[void](Box 4 $yl 5 3.5 $ST.COMPUTE '' $false 9 '0.5 pt'); [void](Label 10 ($yl - 0.8) 48 5 '分辨率不变的块' 8.5 0)
[void](Box 40 $yl 5 3.5 $ST.STORE '' $false 9 '0.5 pt'); [void](Label 46 ($yl - 0.8) 120 5 ('改变分辨率的块（s：下采样步长，r：上采样倍率）') 8.5 0)
[void](Label 4 ($yl + 5) 172 5 ('RG：残差块（GDN）　RB：残差块　RU：上采样残差块（PixelShuffle + IGDN）　ATT：注意力块　数字为输出尺寸 H' + [char]0x00B2 + $X + 'C') 8.5 0)

Save-Figure (Join-Path $here 'fig02_network.vsdx') (Join-Path $repo 'report\figures\network\fig02_network.png')
'saved'
