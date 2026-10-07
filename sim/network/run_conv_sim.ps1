# Layer-level simulation: axis_line_buffer + conv_engine against the golden vectors.
#   powershell -ExecutionPolicy Bypass -File sim\run_conv_sim.ps1 [engine ...]
param([string]$Engines = 'enc.3.ab0.c0,enc.3.a0.c1,enc.2.skip,enc.2.conv1,enc.0.conv1,enc.0.conv2,dec.1.conv1,dec.2.conv+skip',
      [string]$Image = 'div2k_val_00', [int]$ValidPct = 90, [int]$ReadyPct = 80)
$ErrorActionPreference = 'Stop'
$viv    = $(if ($env:XILINX_VIVADO) { Join-Path $env:XILINX_VIVADO 'bin' } else { 'D:\AMDDesignTools\2025.2\Vivado\bin' })
$root   = Split-Path -Parent $PSScriptRoot
$export = (Join-Path $root 'runs\fpga_export_w8a12') -replace '\\', '/'
$work   = Join-Path $PSScriptRoot 'work_conv'
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
    & "$viv\xvlog.bat" -sv "$root\rtl\sdp_ram.sv" "$root\rtl\rom.sv" "$root\rtl\rom_banked.sv" "$root\rtl\axis_line_buffer.sv" `
        "$root\rtl\mul_serial.sv" "$root\rtl\weight_stream.sv" "$root\rtl\conv_engine.sv" "$root\sim\tb_conv_layer.sv" | Out-File out_xvlog.txt
    if ($LASTEXITCODE -ne 0) { Get-Content out_xvlog.txt; throw 'xvlog failed' }
    foreach ($name in ($Engines -split ',')) {
        $e = Get-Content "$export/rtl_init/$name/engine.json" -Raw | ConvertFrom-Json
        $inf  = "$export/golden/$Image/$($e.in).mem"
        $outf = "$export/golden/$Image/$($e.out[0]).mem"
        $g = @("H=$($e.in_shape_hwc[0])", "W=$($e.in_shape_hwc[1])", "CIN=$($e.CIN)", "COUT=$($e.COUT)",
               "K=$($e.K)", "STRIDE=$($e.STRIDE)", "PAD=$($e.PAD)", "P=$($e.P)",
               # xsim keeps quotes as part of a string generic, so string values are passed bare
               "ACT=$($e.ACT)", "ACT2=$($e.ACT2)", "ACT_SPLIT=$($e.ACT_SPLIT)",
               "WROM_STYLE=$($e.WROM_STYLE)", "WROM_BANK_DEPTH=$($e.WROM_BANK_DEPTH)", "RQ_MUL=$($e.RQ_MUL)", "WROM_MODE=$($e.WROM_MODE)", "WG_NCOL=$($e.WG_NCOL)", "PRE=$($e.PRE)", "SH_MIN=$($e.SH_MIN)", "SH_BITS=$($e.SH_BITS)", "INIT_DIR=$export/rtl_init/$name",
               "IN_FILE=$inf", "OUT_FILE=$outf", "VALID_PCT=$ValidPct", "READY_PCT=$ReadyPct")
        if ($e.out.Count -gt 1) { $g += "OUT_FILE2=$export/golden/$Image/$($e.out[1]).mem" }
        $snap = 'conv_' + ($name -replace '[.+]', '_')
        $opts = @('tb_conv_layer', '-s', $snap, '-timescale', '1ns/1ps', '-debug', 'off', '-L', 'xpm')
        foreach ($x in $g) { $opts += @('-generic_top', ('"' + $x + '"')) }
        Set-Content -Path "args_$snap.txt" -Value ($opts -join ' ') -Encoding ascii
        & "$viv\xelab.bat" -f "args_$snap.txt" | Out-File "out_xelab_$snap.txt"
        if ($LASTEXITCODE -ne 0) { Get-Content "out_xelab_$snap.txt" | Select-Object -Last 25; throw "xelab failed: $name" }
        $t = Measure-Command { & "$viv\xsim.bat" $snap -R | Out-File "out_xsim_$snap.txt" }
        $res = Select-String -Path "out_xsim_$snap.txt" -Pattern 'PASS|FAIL|TIMEOUT|MISMATCH|ERROR|Fatal|mismatch' |
               Select-Object -First 6 | ForEach-Object { $_.Line }
        Write-Output ("[{0}] {1}   (sim {2:N0} s)" -f $name, ($res -join ' | '), $t.TotalSeconds)
    }
} finally {
    Pop-Location
}
