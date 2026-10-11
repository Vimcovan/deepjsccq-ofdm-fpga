# Build the competition design report (.docx) from report/sections/*.md with pandoc.
#   powershell -ExecutionPolicy Bypass -File build_docx.ps1 -Template <competition template.docx> [-Pandoc <pandoc.exe>]
# Output: report/build/design_report.docx (and report/build/design_report.md, the concatenated source).
param(
  [Parameter(Mandatory = $true)][string]$Template,
  [string]$Pandoc = $(if ($env:PANDOC) { $env:PANDOC } else { 'pandoc' }),
  [string]$Python = $(if ($env:PYTHON) { $env:PYTHON } else { 'python' }),
  [string]$OutName = 'design_report.docx',
  [switch]$MathType          # formulas as MathType objects (needs desktop MathType + Word, Word must be closed)
)
$ErrorActionPreference = 'Stop'
$tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$report = Split-Path -Parent $tools
$build = Join-Path $report 'build'
New-Item -ItemType Directory -Force $build | Out-Null

$ref = Join-Path $build 'reference.docx'
& $Python -I (Join-Path $tools 'make_reference_docx.py') $Template $ref
if ($LASTEXITCODE -ne 0) { throw 'make_reference_docx.py failed' }

$md = Join-Path $build 'design_report.md'
$parts = Get-ChildItem (Join-Path $report 'sections') -Filter '*.md' | Sort-Object Name
$text = ($parts | ForEach-Object { [IO.File]::ReadAllText($_.FullName).TrimEnd() }) -join "`n`n"
[IO.File]::WriteAllText($md, $text + "`n", (New-Object Text.UTF8Encoding $false))

$out = Join-Path $build $OutName
$lua = Join-Path $tools 'docx_filter.lua'
$filters = @("--lua-filter=$lua")
$pout = $out
if ($MathType) {
  $filters = @("--lua-filter=$(Join-Path $tools 'math_markers.lua')") + $filters
  $pout = $out -replace '\.docx$', '_marked.docx'
}
& $Pandoc $md -f 'markdown-implicit_figures' -o $pout "--reference-doc=$ref" "--resource-path=$report" @filters
if ($LASTEXITCODE -ne 0) { throw 'pandoc failed' }
if ($MathType) {
  & (Join-Path $tools 'mathtype_convert.ps1') -In $pout -Out $out
  Remove-Item $pout
}
"written $out"
