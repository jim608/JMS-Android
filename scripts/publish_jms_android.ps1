param(
    [switch]$DryRun,
    [ValidateSet('prerelease', 'stable')][string]$Channel = 'prerelease'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$env:ANDROID_HOME = Join-Path $root '.jms-tools/android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = 'C:/Program Files/Eclipse Adoptium/jdk-21.0.10.7-hotspot' }
$arguments = @('scripts/publish_jms_release.py', '--channel', $Channel)
if ($DryRun) { $arguments += '--dry-run' }
& rtk proxy (Join-Path $root '.jms-tools/python/Scripts/python.exe') @arguments
if ($LASTEXITCODE -ne 0) { throw 'JMS publication stopped. Read artifacts/publication/preflight.json or the version state; no failed gate is bypassed.' }
