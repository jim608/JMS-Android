param([Parameter(Mandatory = $true)][string]$SourceCommit)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
$python = Join-Path $root '.jms-tools/python/Scripts/python.exe'
$githubCli = Join-Path $root '.jms-tools/gh/bin/gh.exe'
if ($SourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Full source commit required' }
& rtk proxy $python scripts/verify_jms_snapshot.py --commit $SourceCommit
if ($LASTEXITCODE) { throw 'Source snapshot differs; refusing Flatpak build' }
& rtk proxy $python scripts/check_jms_git_privacy.py --tree $SourceCommit
if ($LASTEXITCODE) { throw 'Source privacy gate failed' }
$pushed = & rtk proxy git ls-remote https://github.com/jim608/JMS-Android.git refs/heads/jms
if ($LASTEXITCODE -or ($pushed -split '\s+')[0] -ne $SourceCommit) {
    throw 'Reviewed source must be pushed to the shared jms branch first'
}
& rtk proxy $githubCli workflow run jms-flatpak.yml --repo jim608/JMS-Android --ref jms -f "source_commit=$SourceCommit"
if ($LASTEXITCODE) { throw 'Flatpak workflow dispatch failed' }
Write-Output "Flatpak CI dispatched for $SourceCommit; this does not publish a Release."
