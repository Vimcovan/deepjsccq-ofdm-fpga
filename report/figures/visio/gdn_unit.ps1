# GDN / IGDN layer (axis_gdn.sv + gdn_unit.sv).
#   powershell -ExecutionPolicy Bypass -File gdn_unit.ps1   -> gdn_unit.vsdx + ../hw/gdn_unit.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')

Open-Visio 180 72

$y = 10; $h = 34; $m = $y + $h / 2
[void](Label 1 ($m - 9) 12 8.5 ("x`nNHWC") 7 1 $ST.MUTE $false 2)
[void](Line 1 $m 12 $m)
[void](Box 12 $y 26 $h $ST.STORE ("像素缓存`n（LUTRAM，2 槽轮换）`n`nx[j] 与 x²[j]`n平方：LUT，2 级流水") $false 7)
[void](Line 38 $m 44 $m)
[void](Label 37 ($m - 9) 8 8.5 'x²[j]' 7 1 $ST.MUTE $false 2)
[void](Box 44 $y 34 $h $ST.COMPUTE ("γ 乘加通路 × LANES（DSP）`n`n通路 l、第 g 遍：通道`ni = g·LANES + l`nD_i = β_i + Σ_j γ_ij·x²_j`n读到 j = i 时锁存 x_i") $false 7)
[void](Box 47 ($y + $h + 4) 28 9 $ST.WEIGHT ("γ ROM（按通路打包）`nβ 常数") $false 7)
[void](Line 61 ($y + $h + 4) 61 ($y + $h))
[void](Line 78 $m 84 $m)
[void](Box 84 ($y + 4) 18 ($h - 8) $ST.STORE ("结果`n存储体`n(D_i, x_i)") $false 7)
[void](Line 102 $m 108 $m)
[void](Label 102 ($m - 9) 8 8.5 '派发' 7 1 $ST.MUTE $false 2)
# iterative units
foreach ($k in 0, 1, 2) {
  $uy = $y + $k * 12
  [void](Box 108 $uy 38 10 $ST.COMPUTE ("gdn_unit " + ($k + 1) + "：isqrt（2 位/拍）→`n除法（GDN）或 移位加乘（IGDN）") $false 6.5)
}
[void](Label 108 ($y + 35) 38 5 '共 NUNITS 个，轮询派发与回收' 7 1 $ST.MUTE)
[void](Line 146 $m 152 $m)
[void](Box 152 ($y + 6) 22 ($h - 12) $ST.COMPUTE ("重定标`nsat27 → ×M`n→ rsr → sat12`n（LUT 常数乘）") $false 7)
[void](Line 174 $m 179 $m)
[void](Label 4 60 172 10 ("GDN：t_i = sign(x_i)·⌊|x_i|·2^F / r_i⌋，IGDN：t_i = x_i·r_i，r_i = ⌊√D_i⌋。开方与除法均为恢复式逐位迭代，不用 DSP、不用查找表；结果按派发顺序回收，输出保持通道顺序。") 7.5 0 $ST.MUTE)

Save-Figure (Join-Path $here 'gdn_unit.vsdx') (Join-Path $repo 'report\figures\hw\gdn_unit.png')
'saved'
