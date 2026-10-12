# PHY frame format (top) and subcarrier allocation of one OFDM symbol (bottom).
#   powershell -ExecutionPolicy Bypass -File frame_format.ps1   -> frame_format.vsdx + ../hw/frame_format.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$ROUND = '0 mm'
$repo = Resolve-Path (Join-Path $here '..\..\..')
$X = [char]0x00D7

Open-Visio 180 78

# ---------------------------------------------------------------- frame
$y = 8; $h = 10
[void](Label 2 1 120 6 '(a) 一个 PHY 帧 = 一幅图（54960 个采样，2.748 ms @ 20 MSPS）' 9 0 $ST.INK $true)
[void](Box 4 $y 22 $h $ST.WEIGHT ("STF`n10" + $X + "16") $false 7.5)
[void](Box 26 $y 8 $h $ST.WEIGHT 'GI 32' $false 6.5)
[void](Box 34 $y 14 $h $ST.WEIGHT 'LTF1 64' $false 7)
[void](Box 48 $y 14 $h $ST.WEIGHT 'LTF2 64' $false 7)
[void](Box 62 $y 5 $h $ST.STORE 'CP' $false 6)
[void](Box 67 $y 16 $h $ST.COMPUTE ("数据符号 0`n64") $false 7)
[void](Box 83 $y 5 $h $ST.STORE 'CP' $false 6)
[void](Box 88 $y 16 $h $ST.COMPUTE ("数据符号 1`n64") $false 7)
[void](Box 104 $y 22 $h $null ([string][char]0x2026 + ' 共 683 个 ' + [char]0x2026) $false 7.5)
[void](Box 126 $y 5 $h $ST.STORE 'CP' $false 6)
[void](Box 131 $y 18 $h $ST.COMPUTE ("数据符号 682`n后 16 个补零") $false 6.5)
[void](Box 149 $y 27 $h $ST.GRAY ("帧间隔 50 µs`n（发 0）") $false 7)
[void](Label 4 ($y + $h + 0.5) 58 5 '前导 320 个采样（发射端 ROM）' 7.5 1 $ST.MUTE)
[void](Label 62 ($y + $h + 0.5) 87 5 ('683 ' + $X + ' 80 = 54640 个采样；每符号 48 个数据子载波，32768 = 682' + $X + '48 + 32') 7.5 1 $ST.MUTE)
[void](Label 4 ($y + $h + 6) 172 5 ('用途：STF → 帧检测与 CFO 估计；LTF → 精定时与信道估计（两个 LTF 平均）；导频 → 每个符号的 CPE 与 SFO 跟踪') 7.5 0 $ST.INK)

# ---------------------------------------------------------------- subcarriers
$y2 = 44
[void](Label 2 ($y2 - 13) 160 6 ('(b) 一个 OFDM 符号的 64 个子载波（fftshift 顺序，索引 = 子载波号 + 32）') 9 0 $ST.INK $true)
$w = 2.6; $x0 = 6
$pil = @(11, 25, 39, 53)
for ($k = 0; $k -lt 64; $k++) {
  $x = $x0 + $k * $w
  if ($k -le 5 -or $k -ge 59) { $f = $ST.GRAY } elseif ($k -eq 32) { $f = $ST.PINK } elseif ($pil -contains $k) { $f = $ST.WEIGHT } else { $f = $ST.COMPUTE }
  [void](Box $x $y2 $w 8 $f '' $false 6 '0.4 pt')
}
foreach ($k in @(0, 6, 11, 25, 32, 39, 53, 58, 63)) {
  $x = $x0 + $k * $w
  [void](Label ($x - 3) ($y2 + 8.5) ($w + 6) 4 "$k" 6.5 1 $ST.MUTE)
}
foreach ($p in @(@(11, '−21'), @(25, '−7'), @(39, '+7'), @(53, '+21'))) {
  $x = $x0 + $p[0] * $w
  [void](Label ($x - 4) ($y2 - 5) ($w + 8) 4.5 $p[1] 7 1 $ST.INK)
}
$ly = $y2 + 15
[void](Box 6 $ly 4 3 $ST.COMPUTE '' $false 6 '0.4 pt')
[void](Label 11 ($ly - 1) 40 5 '数据子载波 48 个' 7.5 0)
[void](Box 44 $ly 4 3 $ST.WEIGHT '' $false 6 '0.4 pt'); [void](Label 49 ($ly - 1) 50 5 '导频 4 个（±1024，+21 为负）' 7.5 0)
[void](Box 100 $ly 4 3 $ST.PINK '' $false 6 '0.4 pt'); [void](Label 105 ($ly - 1) 20 5 '直流' 7.5 0)
[void](Box 122 $ly 4 3 $ST.GRAY '' $false 6 '0.4 pt'); [void](Label 127 ($ly - 1) 50 5 '保护带 11 个（填 0）' 7.5 0)

Save-Figure (Join-Path $here 'frame_format.vsdx') (Join-Path $repo 'report\figures\hw\frame_format.png')
'saved'
