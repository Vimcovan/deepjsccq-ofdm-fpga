param([Parameter(Mandatory=$true)][string]$RunDir)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# network library RTL: src/hw/{tx,rx}/rtl/network/rtl (each side holds the modules it uses)
function Rtl([string]$n) { foreach ($s in 'tx', 'rx') { $p = "$repo\src\hw\$s\rtl\network\rtl\$n.sv"; if (Test-Path $p) { return $p } }; throw "$n.sv not found" }
Set-Location $repo
New-Item -ItemType Directory -Force $RunDir | Out-Null
$batch = [ordered]@{
    started = (Get-Date).ToString('o'); pid = $PID; state = 'running'
    simulator = 'xsim (native XPM, assertions enabled)'; image = 'div2k_val_00'
    frames = 2; valid_pct = 90; ready_pct = 80; decoder = 'running'
}
function Save-Status { $batch | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $RunDir 'status.json') -Encoding UTF8 }
Save-Status
$jobDir = Join-Path $RunDir 'decoder'
try {
    & (Join-Path $PSScriptRoot 'run_top_sim.ps1') -First rx_in -Last output -Image div2k_val_00 -Frames 2 -ValidPct 90 -ReadyPct 80 -WorkDir $jobDir *> (Join-Path $RunDir 'decoder.log')
    $out = Join-Path $jobDir 'out_xsim_top_blk_rx_in_output.sized.txt'
    $txt = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    if ($txt -match '(?m)^PASS\s' -and $txt -notmatch '(?im)FAIL|TIMEOUT|MISMATCH|\bERROR\b|\bFATAL\b') {
        $batch.decoder = 'passed'; $batch.state = 'passed'
    } else {
        $batch.decoder = 'failed'; $batch.state = 'failed'
    }
} catch {
    $batch.decoder = 'failed'; $batch.state = 'failed'
    $_ | Out-String | Add-Content (Join-Path $RunDir 'decoder.log')
}
$batch.finished = (Get-Date).ToString('o')
Save-Status
