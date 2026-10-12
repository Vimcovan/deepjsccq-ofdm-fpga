# GDN / IGDN layer (axis_gdn.sv + gdn_unit.sv): hardware blocks only; the arithmetic is described in the text.
#   powershell -ExecutionPolicy Bypass -File gdn_unit.ps1   -> gdn_unit.vsdx + ../hw/gdn_unit.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 186 47

# colours, outlines and corner rounding of the hand-drawn figures (block_rtl.vsdx, fig02_network.vsdx)
$PAL = @{
  CALC  = @('RGB(255,242,204)', 'RGB(127,96,0)')     # compute
  BUF   = @('RGB(219,238,243)', 'RGB(32,88,103)')    # buffers, scheduling
  CONST = @('RGB(235,241,223)', 'RGB(80,99,42)')     # constants
}
function RBox($x, $y, $w, $h, $kind, $text, $size = 7.5) {
  $s = Box $x $y $w $h $PAL[$kind][0] $text $false $size
  $s.CellsU('LineColor').FormulaU = $PAL[$kind][1]
  $s.CellsU('Rounding').FormulaU = '2 mm'
  return $s
}
function Trap($x, $w, $cy, $hNarrow, $hWide, $narrowLeft, $kind, $text, $size = 7.5) {
  # MUX / DEMUX trapezoid: narrow side on the left (DEMUX) or on the right (MUX)
  $l = $(if ($narrowLeft) { $hNarrow } else { $hWide }) / 2
  $r = $(if ($narrowLeft) { $hWide } else { $hNarrow }) / 2
  $pts = @($x, ($cy - $l), ($x + $w), ($cy - $r), ($x + $w), ($cy + $r), $x, ($cy + $l), $x, ($cy - $l))
  $s = Path $pts $false
  $s.CellsU('Geometry1.NoFill').FormulaU = 'FALSE'
  $s.CellsU('FillForegnd').FormulaU = $PAL[$kind][0]; $s.CellsU('FillPattern').FormulaU = '1'
  $s.CellsU('LineColor').FormulaU = $PAL[$kind][1]; $s.CellsU('ShdwPattern').FormulaU = '0'
  $s.Text = $text; Style-Text $s $size
  return $s
}

$m = 22          # centre line of the data path
$h = 14          # height of the main boxes
$t = $m - $h / 2

[void](Label 0 ($m - 7) 8 6 'x' 8 1 $ST.MUTE)
[void](Line 0 $m 8 $m)
[void](RBox 8 $t 15 $h CALC ("平方`n（LUT）"))
[void](Line 23 $m 28 $m)
[void](RBox 28 $t 19 $h BUF ("像素缓存`n（乒乓）"))
[void](Line 47 $m 55 $m)
[void](Label 47 ($m - 7) 8 6 'x, x²' 7 1 $ST.MUTE)
[void](RBox 55 $t 19 $h CALC ("乘加通路 ×L`n（DSP）"))
[void](RBox 55 ($t + $h + 7) 19 9 CONST ("γ ROM，β"))
[void](Line 64.5 ($t + $h + 7) 64.5 ($t + $h))
[void](Line 74 $m 79 $m)
[void](RBox 79 $t 17 $h BUF ("分母寄存器`n×L"))
[void](Line 96 $m 104 $m)
[void](Label 96 ($m - 7) 8 6 'D, x' 7 1 $ST.MUTE)

# round-robin dispatch (DEMUX) -> N iterative units -> round-robin collect (MUX)
[void](Trap 104 9 $m 18 34 $true BUF ("轮`n询`n派`n发"))
$uy = @(($m - 15), ($m - 4), ($m + 9))
$ut = @('开方 / 除法单元 1', '开方 / 除法单元 2', '开方 / 除法单元 N')
for ($k = 0; $k -lt 3; $k++) {
  $cy = $uy[$k] + 3.5
  [void](Line 113 $cy 119 $cy)
  [void](RBox 119 $uy[$k] 26 7 CALC $ut[$k] 7)
  [void](Line 145 $cy 151 $cy)
}
[void](Label 119 ($m + 3.5) 26 5 '⋮' 11 1)
[void](Trap 151 9 $m 18 34 $false BUF ("轮`n询`n回`n收"))
[void](Line 160 $m 165 $m)

[void](RBox 165 $t 13 $h CALC ("重定标`n（LUT）"))
[void](Line 178 $m 183 $m)
[void](Label 178 ($m - 7) 6 6 'y' 8 1 $ST.MUTE)

Save-Figure (Join-Path $here 'gdn_unit.vsdx') (Join-Path $repo 'report\figures\hw\gdn_unit.png')
'saved'


