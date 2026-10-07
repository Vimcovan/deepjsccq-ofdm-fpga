# GDN / IGDN layer simulation against the golden vectors.
#   powershell -ExecutionPolicy Bypass -File sim\run_gdn_sim.ps1 [-Layers enc.0.gdn,dec.9.igdn]
param([string]$Layers = 'enc.0.gdn,enc.7.gdn,dec.7.igdn,dec.9.igdn',
      [string]$Image = 'div2k_val_00', [int]$ValidPct = 100, [int]$ReadyPct = 100)
$ErrorActionPreference = 'Stop'
$viv    = 'D:\AMDDesignTools\2025.2\Vivado\bin'
$root   = Split-Path -Parent $PSScriptRoot
$export = (Join-Path $root 'runs\fpga_export_w8a12') -replace '\\', '/'
$work   = Join-Path $PSScriptRoot 'work_gdn'
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
    & "$viv\xvlog.bat" -sv "$root\rtl\gdn_unit.sv" "$root\rtl\axis_gdn.sv" "$root\sim\tb_gdn.sv" | Out-File out_xvlog.txt
    if ($LASTEXITCODE -ne 0) { Get-Content out_xvlog.txt; throw 'xvlog failed' }
    foreach ($name in ($Layers -split ',')) {
        $e = Get-Content "$export/rtl_init/$name/gdn.json" -Raw | ConvertFrom-Json
        $g = @("H=$($e.shape_hwc[0])", "W=$($e.shape_hwc[1])", "C=$($e.C)", "LANES=$($e.LANES)",
               "INVERSE=$($e.INVERSE)", "X2_SHIFT=$($e.X2_SHIFT)", "LSH=$($e.LSH)", "F=$($e.F)", "QW=$($e.QW)",
               "DW=$($e.DW)", "NUNITS=$($e.NUNITS)", "PRE=$($e.PRE)", "M=$($e.M)", "SH=$($e.SH)",
               "INIT_DIR=$export/rtl_init/$name", "IN_FILE=$export/golden/$Image/$($e.in).mem",
               "OUT_FILE=$export/golden/$Image/$($e.out).mem", "VALID_PCT=$ValidPct", "READY_PCT=$ReadyPct")
        $snap = 'gdn_' + ($name -replace '[.+]', '_')
        $opts = @('tb_gdn', '-s', $snap, '-timescale', '1ns/1ps', '-debug', 'off')
        foreach ($x in $g) { $opts += @('-generic_top', ('"' + $x + '"')) }
        Set-Content -Path "args_$snap.txt" -Value ($opts -join ' ') -Encoding ascii
        & "$viv\xelab.bat" -f "args_$snap.txt" | Out-File "out_xelab_$snap.txt"
        if ($LASTEXITCODE -ne 0) { Get-Content "out_xelab_$snap.txt" | Select-Object -Last 25; throw "xelab failed: $name" }
        $t = Measure-Command { & "$viv\xsim.bat" $snap -R | Out-File "out_xsim_$snap.txt" }
        $res = Select-String -Path "out_xsim_$snap.txt" -Pattern 'PASS|FAIL|MISMATCH|ERROR|Error|Fatal' |
               Select-Object -First 6 | ForEach-Object { $_.Line }
        Write-Output ("[{0}] budget {1:N0} cycles/frame; {2}   (sim {3:N0} s)" -f $name, $e.budget_cycles, ($res -join ' | '), $t.TotalSeconds)
    }
} finally {
    Pop-Location
}
