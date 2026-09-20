param(
    [Parameter(Mandatory=$true)][string]$Apk,
    [string]$Notes = 'docs/JMS_RELEASE_NOTES.zh-Hant.md',
    [string]$BuildRecord = '',
    [switch]$RequirePublicationReady
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$arguments = @('scripts/package_jms_sources.py', '--release', '--apk', $Apk, '--notes', $Notes)
if ($RequirePublicationReady) { $arguments += '--require-publication-ready' }
if ($BuildRecord -ne '') { $arguments += @('--build-record', $BuildRecord) }
& rtk proxy (Join-Path $root '.jms-tools/python/Scripts/python.exe') @arguments
if ($LASTEXITCODE -ne 0) { throw 'Local release preparation refused; see the validation error. Nothing was uploaded.' }
