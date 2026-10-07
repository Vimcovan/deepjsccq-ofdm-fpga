param(
    [string]$Top = 'blk_enc_0_latent_idx',
    [int]$Threads = 4,
    [string]$RunDir = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (!$RunDir) { $RunDir = Join-Path $root ('syn\run_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
New-Item -ItemType Directory -Force $RunDir | Out-Null
$statusPath = Join-Path $RunDir 'status.json'
$logPath = Join-Path $RunDir 'vivado.log'
$errPath = Join-Path $RunDir 'vivado.err.log'
$status = [ordered]@{
    started = (Get-Date).ToString('o'); state = 'running'; top = $Top
    threads = $Threads; log = $logPath; error_log = $errPath
}
function Save-Status { $status | ConvertTo-Json -Depth 4 | Set-Content $statusPath -Encoding UTF8 }
Save-Status
$vivado = 'D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
$tcl = Join-Path $root 'syn\synth_top.tcl'
$env:VIVADO_MAX_THREADS = [string]$Threads
try {
    & $vivado -mode batch -source $tcl -tclargs $Top *> $logPath
    $status.exit_code = $LASTEXITCODE
    $text = Get-Content $logPath -Raw
    if ($LASTEXITCODE -eq 0 -and $text -match '(?m)^RESULT\s') { $status.state = 'passed' }
    else { $status.state = 'failed' }
} catch {
    $_ | Out-String | Set-Content $errPath -Encoding UTF8
    $status.state = 'failed'; $status.exit_code = 1
}
$status.finished = (Get-Date).ToString('o')
Save-Status
