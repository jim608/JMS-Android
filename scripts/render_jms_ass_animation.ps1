$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$source = 'artifacts/subtitles/source.mp4'
if (-not (Test-Path -LiteralPath $source)) { throw 'Run generate_jms_subtitle_fixtures.py first' }
$output = 'artifacts/subtitles/reference-effects-m6.mp4'
$ErrorActionPreference = 'Continue'
& rtk proxy ffmpeg -hide_banner -y -i $source -vf 'ass=test/fixtures/subtitles/representative.ass:fontsdir=assets/subtitle_fonts' -c:v libx264 -preset fast -crf 18 -c:a copy $output *> artifacts/checks/reference-animation-m6.log
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw 'Reference rendering failed; see reference-animation-m6.log' }
Get-FileHash -LiteralPath $output -Algorithm SHA256
Write-Output 'FFmpeg/libass reference only, NOT Android client rendering or server-burn-in acceptance.'
