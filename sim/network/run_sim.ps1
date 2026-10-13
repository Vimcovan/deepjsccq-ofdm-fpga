# Compile axis_line_buffer + testbench once, then elaborate/run several parameter sets with xsim.
#   powershell -ExecutionPolicy Bypass -File sim\run_sim.ps1
$ErrorActionPreference = 'Stop'
$viv  = $(if ($env:XILINX_VIVADO) { Join-Path $env:XILINX_VIVADO 'bin' } else { 'D:\AMDDesignTools\2025.2\Vivado\bin' })
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# network library RTL: src/hw/{tx,rx}/rtl/network/rtl (each side holds the modules it uses)
function Rtl([string]$n) { foreach ($s in 'tx', 'rx') { $p = "$repo\src\hw\$s\rtl\network\rtl\$n.sv"; if (Test-Path $p) { return $p } }; throw "$n.sv not found" }
$work = Join-Path $PSScriptRoot 'work'
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
    & "$viv\xvlog.bat" -sv (Rtl sdp_ram) (Rtl axis_line_buffer) "$PSScriptRoot\tb_axis_line_buffer.sv" | Out-File out_xvlog.txt
    if ($LASTEXITCODE -ne 0) { Get-Content out_xvlog.txt; throw 'xvlog failed' }

    $cases = @(
        @{ name = 'c8_s1_pack3';        g = @('C=8','W=16','H=10','GROUPS=2','PACK=3') },
        @{ name = 'c8_s1_pack3_full';   g = @('C=8','W=16','H=10','GROUPS=2','PACK=3','VALID_PCT=100','READY_PCT=100') },
        @{ name = 'rgb_s2_pack1';       g = @('DATA_W=8','C=3','W=20','H=12','STRIDE=2','GROUPS=1','PACK=1') },
        @{ name = 'c32_pack6_midword';  g = @('C=32','W=8','H=6','GROUPS=3','PACK=6') },
        @{ name = 'c4_pack5_ultra_rl1'; g = @('C=4','W=7','H=5','GROUPS=1','PACK=5','RAM_STYLE=ultra','RAM_LATENCY=1') },
        @{ name = 'k1_s2_unused_rows';  g = @('C=8','W=10','H=10','K=1','STRIDE=2','PAD=0','GROUPS=2','PACK=3','FRAMES=4') },
        @{ name = 'c16_s2_pack4_dist';  g = @('C=16','W=12','H=9','STRIDE=2','GROUPS=1','PACK=4','RAM_STYLE=distributed','VALID_PCT=95','READY_PCT=30') }
    )
    foreach ($c in $cases) {
        # options go through an argument file: cmd.exe would split 'C=8' at the '=' sign
        $opts = @('tb_axis_line_buffer', '-s', $c.name, '-timescale', '1ns/1ps', '-debug', 'off')
        foreach ($g in $c.g) { $opts += @('-generic_top', ('"' + $g + '"')) }
        $argf = "args_$($c.name).txt"
        Set-Content -Path $argf -Value ($opts -join ' ') -Encoding ascii
        & "$viv\xelab.bat" -f $argf | Out-File "out_xelab_$($c.name).txt"
        if ($LASTEXITCODE -ne 0) { Get-Content "out_xelab_$($c.name).txt" | Select-Object -Last 20; throw "xelab failed: $($c.name)" }
        & "$viv\xsim.bat" $c.name -R | Out-File "out_xsim_$($c.name).txt"
        $res = Select-String -Path "out_xsim_$($c.name).txt" -Pattern 'PASS|FAIL|TIMEOUT|MISMATCH|ERROR|Fatal' | ForEach-Object { $_.Line }
        Write-Output ("[{0}] {1}" -f $c.name, ($res -join ' | '))
    }
} finally {
    Pop-Location
}
