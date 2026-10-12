# Off-screen 3-D |H| rendering on the Mali-400 (jscc_gui.py H3DWorker / H3DView + h3d_render.py).
#   powershell -ExecutionPolicy Bypass -File gpu_pipeline.ps1   -> gpu_pipeline.vsdx + ../sw/gpu_pipeline.png
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'visio_style.ps1')
$repo = Resolve-Path (Join-Path $here '..\..\..')
$ST.SIZE = 7

Open-Visio 180 104

# ---------------------------------------------------------------- GUI process
[void](Box 2 4 54 96 $null '' $true 8 '0.5 pt')
[void](Label 4 5 50 5 'GUI 进程 jscc_gui.py（Qt）' 8 0 $ST.INK $true)
[void](Box 6 13 46 13 $ST.COMPUTE ("收到遥测快照时`nLTF → |H|（52 个子载波，dB）`n追加到最近 5 s 的历史"))
[void](Line 29 26 29 31)
[void](Box 6 31 46 14 $ST.STORE ("三维渲染工作线程`n最多一个请求在途`n新请求覆盖未发出的旧请求"))
[void](Line 29 45 29 72)
[void](Label 30 55 22 5 '收到图像后触发重绘' 6.5 0 $ST.MUTE)
[void](Box 6 72 46 16 $ST.COMPUTE ("三维视图控件重绘时`n贴图 + 用同一套相机与投影参数`n画坐标轴刻度文字"))
[void](Line 29 88 29 93)
[void](Label 6 93 46 5 '→ 触摸屏（X 服务，2D）' 7 1 $ST.INK)

# ---------------------------------------------------------------- pipe
[void](Path @(52, 35, 59, 35, 59, 40, 70, 40))
[void](Label 59.5 28 7 7 ("stdin`n请求") 6 1 $ST.MUTE)
[void](Path @(70, 73, 64, 73, 64, 42, 52, 42))
[void](Label 56.5 55 7.5 7 ("stdout`n图像") 6 1 $ST.MUTE)

# ---------------------------------------------------------------- renderer process
[void](Box 66 4 64 96 $null '' $true 8 '0.5 pt')
[void](Label 68 5 60 5 '渲染进程 h3d_render.py（不经过 X）' 8 0 $ST.INK $true)
[void](Box 70 13 56 16 $ST.WEIGHT ("启动：按驱动名找 lima 的 renderD 节点`nGBM 设备 → EGL（PLATFORM_GBM）`n→ GLES 2.0 无表面上下文 → FBO`n（RGBA 纹理 + 16 位深度）"))
[void](Line 98 29 98 33)
[void](Box 70 33 56 14 $ST.COMPUTE ("几何生成（NumPy，约 7 ms）`nT×N 三角网格、有限差分法向、Lambert 着色`n网格线 / 地面网格 / 坐标轴线段"))
[void](Line 98 47 98 51)
[void](Box 70 51 56 13 $ST.COMPUTE ("渲染：上传顶点缓冲（VBO）`n先画曲面（多边形偏移），再画线段`n投影矩阵 y 方向预翻转"))
[void](Line 98 64 98 68)
[void](Box 70 68 56 10 $ST.COMPUTE ("glReadPixels → RGBA（约 45 ms）"))

# ---------------------------------------------------------------- GPU
[void](Box 136 13 40 68 $ST.GREEN ("Mali-400 MP2`n（1 GP + 2 PP，500 MHz）`n`nlima 内核驱动`n（外部模块，板上编译）`n`nMesa 22 lima_dri`nOpenGL ES 2.0") $false 7)
[void](Line 126 57.5 136 57.5)
[void](Line 136 73 126 73)
[void](Label 134 84 44 16 ("每帧约 60 ms，曲面每秒刷新 2.5 次；`n渲染进程约占一个核的 10 %") 7 0 $ST.INK)

Save-Figure (Join-Path $here 'gpu_pipeline.vsdx') (Join-Path $repo 'report\figures\sw\gpu_pipeline.png')
'saved'
