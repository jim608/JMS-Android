$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root '.jms-tools/ass-samples'
New-Item -ItemType Directory -Force $directory | Out-Null
$destination = Join-Path $directory 'kyokusai-chs-jpn.ass'
$url = 'https://raw.githubusercontent.com/KyokuSai/ASSFun/036a3e5ef3ff60d412647a6bf960a672f4f1a342/%5BKyokuSai%5D%20sample%20%5BCHS_JPN%5D.kawaii.ass'
$expected = '7251492e714849b732bf8a8c61d84ad96c27619f89151fb2fac823a6119dd22d'
if (-not (Test-Path -LiteralPath $destination)) {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $destination
}
if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Public ASS sample checksum mismatch; refusing to overwrite existing input'
}
Write-Output 'PASS: pinned public Chinese/Japanese ASS sample verified. No repository license declared; local evaluation only, excluded from APK/source/evidence packages.'
