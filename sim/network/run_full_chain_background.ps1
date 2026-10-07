# Detached batch: keep both full-chain results, even if the first chain fails.
param([Parameter(Mandatory=$true)][string]$RunDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
New-Item -ItemType Directory -Force $RunDir | Out-Null
$batch = [ordered]@{
    started = (Get-Date).ToString('o'); pid = $PID; state = 'running'
    simulator = 'xsim (native XPM, assertions enabled)'
    image = 'div2k_val_00'; frames = 2; valid_pct = 90; ready_pct = 80
    encoder = 'queued'; decoder = 'queued'
}
function Save-Status {
    $batch | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $RunDir 'status.json') -Encoding UTF8
}
Save-Status
foreach ($job in @(
    @{ name='encoder'; first='enc.0'; last='latent_idx' },
    @{ name='decoder'; first='rx_in'; last='output' }
)) {
    $batch[$job.name] = 'running'
    Save-Status
    $jobDir = Join-Path $RunDir $job.name
    try {
        & (Join-Path $PSScriptRoot 'run_top_sim.ps1') -First $job.first -Last $job.last `
            -Image div2k_val_00 -Frames 2 -ValidPct 90 -ReadyPct 80 -WorkDir $jobDir `
            *> (Join-Path $RunDir ($job.name + '.log'))
        $batch[$job.name] = 'passed'
    } catch {
        $batch[$job.name] = 'failed'
        $_ | Out-String | Add-Content (Join-Path $RunDir ($job.name + '.log'))
    }
    Save-Status
}
$batch.state = if ($batch.encoder -eq 'passed' -and $batch.decoder -eq 'passed') { 'passed' } else { 'failed' }
$batch['finished'] = (Get-Date).ToString('o')
Save-Status
