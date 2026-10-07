# QuestaSim regression for a generated top.  ROMs use inferred memories under
# QUESTA_SIM, so this does not require Vivado's XPM simulation library.
param(
    [string]$First = 'enc.3', [string]$Last = '',
    [string]$Image = 'div2k_val_00', [int]$ValidPct = 90,
    [int]$ReadyPct = 80, [int]$Frames = 1,
    [long]$MaxCycles = 60000000
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$py = 'D:\CodexPrj\DeepJSCC\DeepJSCC_retrain_bundle_20260901\.venv\Scripts\python.exe'
$questa = 'D:\questasim64_2024.1\win64'
$export = (Join-Path $root 'runs\fpga_export_w8a12') -replace '\\', '/'
if ($Last -eq '') { $Last = $First }
$msg = & $py (Join-Path $root 'gen_rtl_top.py') $First $Last
if ($LASTEXITCODE -ne 0) { throw 'gen_rtl_top failed' }
$mod = ($msg -split ':')[0]
$info = Get-Content (Join-Path $root "rtl\gen\$mod.json") -Raw | ConvertFrom-Json
$work = Join-Path $PSScriptRoot ('work_questa_' + ($mod -replace '[.]', '_'))
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
    if (!(Test-Path 'work')) { & (Join-Path $questa 'vlib.exe') work }
    $src = @('sdp_ram','rom','rom_banked','axis_line_buffer','axis_pixel_buffer',
             'mul_serial','weight_stream','conv_engine','axis_fork','axis_tag',
             'axis_split','centre_tap','axis_fifo_packed','gdn_unit','axis_gdn',
             'axis_add','axis_sigmoid','axis_gate','axis_pixel_shuffle','qam_tx','rx_frame') |
             ForEach-Object { Join-Path $root "rtl\$_.sv" }
    $src += Join-Path $root "rtl\gen\$mod.sv"
    $src += Join-Path $root 'sim\tb_top.sv'
    & (Join-Path $questa 'vlog.exe') -sv "+define+BLK=$mod" '+define+QUESTA_SIM' @src | Out-File vlog.log
    if ($LASTEXITCODE -ne 0) { Get-Content vlog.log -Tail 40; throw 'vlog failed' }
    $inFile = if ([int]$info.IN_W -eq 24) { "$export/golden/$Image/rx_iq24.mem" } else { "$export/golden/$Image/$($info.in).mem" }
    $outFile = if ([int]$info.OUT_W -eq 24) { "$export/golden/$Image/tx_iq24.mem" } else { "$export/golden/$Image/$($info.out).mem" }
    $args = @('-c','-lib','work','tb_top','-do','run -all; quit -f',
              "-gSEED=7", "-gH=$($info.H)", "-gW=$($info.W)", "-gCIN=$($info.CIN)",
              "-gHO=$($info.HO)", "-gWO=$($info.WO)", "-gCOUT=$($info.COUT)",
              "-gOUT_W=$($info.OUT_W)", "-gIN_W=$($info.IN_W)",
              "-gIN_ELEMS=$($info.IN_ELEMS)", "-gOUT_ELEMS=$($info.OUT_ELEMS)",
              "-gIN_FILE=$inFile", "-gOUT_FILE=$outFile",
              "-gVALID_PCT=$ValidPct", "-gREADY_PCT=$ReadyPct",
              "-gNFRAMES=$Frames", "-gMAX_CYCLES=$MaxCycles")
    & (Join-Path $questa 'vsim.exe') @args *> questa_run.log
    $simExit = $LASTEXITCODE
    $simText = Get-Content questa_run.log -Raw
    Get-Content questa_run.log -Tail 30
    if ($simExit -ne 0 -or $simText -notmatch '(?m)^# PASS\s' -or
        $simText -match '(?im)\bFAIL\b|TIMEOUT|MISMATCH|\*\* (Error|Fatal)|Errors: [1-9]') {
        throw "Simulation failed or did not finish: $work\questa_run.log (exit $simExit)"
    }
} finally { Pop-Location }
