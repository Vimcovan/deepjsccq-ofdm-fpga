# Shared Visio helpers and style for the report figures (dot-source this file).
# Style follows report/figures/network/fig05_conv_engine.png: SimSun for CJK, Times New Roman for Latin text,
# light fills, thin black outlines and arrows. Coordinates are in millimetres from the TOP-LEFT corner of the page.

$ST = @{
  WEIGHT = 'RGB(255,242,204)'   # weight ROM / constants
  COMPUTE = 'RGB(220,237,243)'  # compute units
  STORE = 'RGB(182,221,231)'    # buffers / storage
  OPTION = 'RGB(236,241,223)'   # optional block (dashed)
  PINK = 'RGB(230,185,182)'
  GREEN = 'RGB(214,227,191)'
  GRAY = 'RGB(242,242,242)'
  INK = 'RGB(0,0,0)'
  MUTE = 'RGB(89,89,89)'
  LATIN = 'Times New Roman'
  CJK = '宋体'
  SIZE = 9
}

function Open-Visio($widthMM, $heightMM) {
  $script:app = New-Object -ComObject Visio.InvisibleApp
  $script:doc = $app.Documents.Add('')
  $script:page = $doc.Pages.Item(1)
  $script:PW = $widthMM; $script:PH = $heightMM
  $page.PageSheet.CellsU('PageWidth').FormulaU = "$widthMM mm"
  $page.PageSheet.CellsU('PageHeight').FormulaU = "$heightMM mm"
  $script:fLatin = $doc.Fonts.Item($ST.LATIN).ID
  $script:fCJK = $doc.Fonts.Item($ST.CJK).ID
}

function In($mm) { return $mm / 25.4 }

function Style-Text($s, $size = $ST.SIZE, $color = $ST.INK, $bold = $false, $halign = 1, $valign = 1) {
  $s.CellsU('Char.Font').FormulaU = "$fLatin"
  $s.CellsU('Char.AsianFont').FormulaU = "$fCJK"
  $s.CellsU('Char.Size').FormulaU = "$size pt"
  $s.CellsU('Char.Color').FormulaU = $color
  $s.CellsU('Char.Style').FormulaU = $(if ($bold) { '1' } else { '0' })
  $s.CellsU('Para.HorzAlign').FormulaU = "$halign"          # 0 left, 1 centre, 2 right
  $s.CellsU('VerticalAlign').FormulaU = "$valign"           # 0 top, 1 middle, 2 bottom
  foreach ($m in 'LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin') { $s.CellsU($m).FormulaU = '1 pt' }
}

function Box($x, $y, $w, $h, $fill, $text = '', $dashed = $false, $size = $ST.SIZE, $lineW = '0.75 pt') {
  $s = $page.DrawRectangle((In $x), (In ($PH - $y - $h)), (In ($x + $w)), (In ($PH - $y)))
  if ($fill) { $s.CellsU('FillForegnd').FormulaU = $fill; $s.CellsU('FillPattern').FormulaU = '1' }
  else { $s.CellsU('FillPattern').FormulaU = '0' }
  $s.CellsU('LineColor').FormulaU = $ST.INK
  $s.CellsU('LineWeight').FormulaU = $lineW
  $s.CellsU('LinePattern').FormulaU = $(if ($dashed) { '2' } else { '1' })
  $s.CellsU('ShdwPattern').FormulaU = '0'
  if ($text) { $s.Text = $text; Style-Text $s $size }
  return $s
}

function Label($x, $y, $w, $h, $text, $size = $ST.SIZE, $halign = 0, $color = $ST.INK, $bold = $false, $valign = 1) {
  $s = $page.DrawRectangle((In $x), (In ($PH - $y - $h)), (In ($x + $w)), (In ($PH - $y)))
  $s.CellsU('FillPattern').FormulaU = '0'; $s.CellsU('LinePattern').FormulaU = '0'; $s.CellsU('ShdwPattern').FormulaU = '0'
  $s.Text = $text
  Style-Text $s $size $color $bold $halign $valign
  return $s
}

function Line($x1, $y1, $x2, $y2, $arrow = $true, $dashed = $false, $color = $ST.INK, $w = '0.75 pt') {
  $l = $page.DrawLine((In $x1), (In ($PH - $y1)), (In $x2), (In ($PH - $y2)))
  $l.CellsU('LineColor').FormulaU = $color
  $l.CellsU('LineWeight').FormulaU = $w
  $l.CellsU('LinePattern').FormulaU = $(if ($dashed) { '2' } else { '1' })
  if ($arrow) { $l.CellsU('EndArrow').FormulaU = '4'; $l.CellsU('EndArrowSize').FormulaU = '1' }
  return $l
}

function Circle($cx, $cy, $r, $text, $size = 10) {
  $s = $page.DrawOval((In ($cx - $r)), (In ($PH - $cy - $r)), (In ($cx + $r)), (In ($PH - $cy + $r)))
  $s.CellsU('FillForegnd').FormulaU = 'RGB(255,255,255)'; $s.CellsU('LineColor').FormulaU = $ST.INK
  $s.CellsU('LineWeight').FormulaU = '0.75 pt'; $s.CellsU('ShdwPattern').FormulaU = '0'
  $s.Text = $text; Style-Text $s $size
  return $s
}

function Dot($cx, $cy, $r = 0.7) {
  $s = $page.DrawOval((In ($cx - $r)), (In ($PH - $cy - $r)), (In ($cx + $r)), (In ($PH - $cy + $r)))
  $s.CellsU('FillForegnd').FormulaU = $ST.INK; $s.CellsU('LinePattern').FormulaU = '0'; $s.CellsU('ShdwPattern').FormulaU = '0'
  return $s
}

function Path($pts, $arrow = $true, $dashed = $false) {
  # polyline through points @(x1,y1, x2,y2, ...) in mm from the top-left corner
  $xy = New-Object 'double[]' $pts.Count
  for ($i = 0; $i -lt $pts.Count; $i += 2) { $xy[$i] = In $pts[$i]; $xy[$i + 1] = In ($PH - $pts[$i + 1]) }
  $l = $page.DrawPolyline($xy, 0)
  $l.CellsU('LineColor').FormulaU = $ST.INK; $l.CellsU('LineWeight').FormulaU = '0.75 pt'
  $l.CellsU('LinePattern').FormulaU = $(if ($dashed) { '2' } else { '1' }); $l.CellsU('FillPattern').FormulaU = '0'
  if ($arrow) { $l.CellsU('EndArrow').FormulaU = '4'; $l.CellsU('EndArrowSize').FormulaU = '1' }
  return $l
}

function Save-Figure($vsdx, $png, $dpi = 300) {
  if (Test-Path $vsdx) { Remove-Item $vsdx }
  $doc.SaveAs($vsdx)
  $app.Settings.SetRasterExportResolution(3, $dpi, $dpi, 0)   # custom resolution, pixels per inch
  $app.Settings.RasterExportBackgroundColor = 16777215         # white
  if (Test-Path $png) { Remove-Item $png }
  $page.Export($png)
  $doc.Close(); $app.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null
}
