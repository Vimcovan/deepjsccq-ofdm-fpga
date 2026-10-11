# Turn the LaTeX markers written by math_markers.lua into MathType equations (Equation.DSMT4 OLE objects).
# Uses the desktop MathType Word add-in ("MathType Commands 2016.dotm", command MTCommand_TeXToggle) through Word COM.
#   powershell -ExecutionPolicy Bypass -File mathtype_convert.ps1 -In report\build\x_marked.docx -Out report\build\x.docx
# Refuses to run while Word is open (it starts and quits its own hidden Word instance).
param([Parameter(Mandatory = $true)][string]$In, [Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
if (Get-Process WINWORD -ErrorAction SilentlyContinue) { throw 'Word is running: close it first (this script quits its Word instance)' }
$In = (Resolve-Path $In).Path
$t0 = Get-Date
$w = New-Object -ComObject Word.Application
$w.Visible = $false; $w.DisplayAlerts = 0
$ok = 0; $bad = @()
try {
  $d = $w.Documents.Open($In, $false, $false)
  while ($true) {
    $r = $d.Content
    $f = $r.Find
    $f.ClearFormatting(); $f.MatchWildcards = $false
    if (-not $f.Execute('@@MT')) { break }
    $start = $r.Start
    $e = $d.Range($start, $d.Content.End)
    if (-not $e.Find.Execute('}MT@@')) { throw "unterminated marker at $start" }
    $rg = $d.Range($start, $e.End)
    $t = $rg.Text
    $display = $t.StartsWith('@@MTD{')
    $latex = $t.Substring($(if ($display) { 6 } else { 5 }), $t.Length - $(if ($display) { 6 } else { 5 }) - 5)
    # display formulas: single $ with \displaystyle (the $$ form is not converted by the add-in); the paragraph is centred
    $rg.Text = $(if ($display) { '$\displaystyle ' + $latex.Trim() + '$' } else { '$' + $latex + '$' })
    # the add-in leaves text in the custom EquationPara style untouched: convert in Normal, then restore the style
    $para = $d.Range($start, $start).Paragraphs.Item(1)
    if ($display) { $para.Style = $d.Styles.Item(-1) }
    $d.Range($start, $start + $rg.Text.Length).Select()
    $w.Run('MTCommand_TeXToggle')
    if ($display) { $d.Range($start, $start).Paragraphs.Item(1).Style = 'EquationPara' }
    if ($d.Range($start, $start + 1).Text -ne '$') { $ok++ }
    else {
      $bad += $latex
      $end = $d.Range($start + 1, $d.Content.End); [void]$end.Find.Execute('$')
      $d.Range($start, $end.End).Text = '[[TeX: ' + $latex + ']]'   # leave visible, avoid an endless loop
    }
  }
  $d.SaveAs2([IO.Path]::GetFullPath($Out), 16)
  $d.Close(0)
} finally {
  $w.Quit(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($w)
  # the hidden instance sometimes lingers after Quit: stop only Word processes without a window started by this script
  for ($i = 0; $i -lt 10 -and (Get-Process WINWORD -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
  Get-Process WINWORD -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $t0 -and $_.MainWindowHandle -eq 0 } |
    ForEach-Object { Stop-Process -Id $_.Id -Confirm:$false }
}
"MathType equations: $ok converted, $($bad.Count) failed"
$bad | ForEach-Object { "  failed: $_" }
