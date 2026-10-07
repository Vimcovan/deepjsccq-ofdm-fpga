$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = Join-Path $root 'data'
$log = Join-Path $root 'logs\flickr2k_download.log'
New-Item -ItemType Directory -Force -Path $data,(Join-Path $root 'logs') | Out-Null
$tar = Join-Path $data 'Flickr2K.tar'
$url = 'https://cv.snu.ac.kr/research/EDSR/Flickr2K.tar'
& curl.exe --http1.1 -L --fail --retry 20 --retry-delay 10 --retry-all-errors --connect-timeout 30 --continue-at - --output $tar $url *> $log
if ($LASTEXITCODE -ne 0) { throw "Flickr2K download failed with exit code $LASTEXITCODE" }
$dest = Join-Path $data 'Flickr2K'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
tar -xf $tar -C $dest
Set-Content -Path (Join-Path $data 'Flickr2K_READY.txt') -Value (Get-Date -Format o)
