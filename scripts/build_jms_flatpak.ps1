param(
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [long]$NativeRunId = 0
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
$python = Join-Path $root '.jms-tools/python/Scripts/python.exe'
$githubCli = Join-Path $root '.jms-tools/gh/bin/gh.exe'
if ($SourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Full source commit required' }
if ($NativeRunId -lt 0) { throw 'Native run ID must be positive when provided' }
if ($NativeRunId) {
    $dirty = & rtk proxy git status --porcelain
    if ($LASTEXITCODE -or -not [string]::IsNullOrWhiteSpace(($dirty -join "`n"))) {
        throw 'Commit and review verification tools before resuming the candidate'
    }
    & rtk proxy git merge-base --is-ancestor $SourceCommit HEAD
    if ($LASTEXITCODE) { throw 'Candidate source is not an ancestor of verification tools' }
    & rtk proxy git diff --quiet $SourceCommit HEAD -- Dockerfile.linux 'pubspec.*' .fvmrc l10n.yaml .dockerignore .gitattributes .gitmodules lib linux third_party flatpak assets icons LICENSE
    if ($LASTEXITCODE) { throw 'App/native/build inputs changed; refusing bundle reuse' }
    & rtk proxy $python scripts/check_jms_git_privacy.py --tree HEAD
    if ($LASTEXITCODE) { throw 'Verification tools privacy gate failed' }
} else {
    & rtk proxy $python scripts/verify_jms_snapshot.py --commit $SourceCommit
    if ($LASTEXITCODE) { throw 'Source snapshot differs; refusing Flatpak build' }
}
& rtk proxy $python scripts/check_jms_git_privacy.py --tree $SourceCommit
if ($LASTEXITCODE) { throw 'Source privacy gate failed' }
$pushed = & rtk proxy git ls-remote https://github.com/jim608/JMS-Android.git refs/heads/jms
if ($LASTEXITCODE) { throw 'Shared jms branch could not be verified' }
$pushedHead = ($pushed -split '\s+')[0]
$verificationHead = & rtk proxy git rev-parse HEAD
if ($LASTEXITCODE -or $pushedHead -notmatch '^[a-f0-9]{40}$' -or
    ($NativeRunId -and $pushedHead -ne $verificationHead) -or
    (-not $NativeRunId -and $pushedHead -ne $SourceCommit)) {
    throw 'Reviewed source must be pushed to the shared jms branch first'
}
$dispatch = @('workflow', 'run', 'jms-flatpak.yml', '--repo', 'jim608/JMS-Android', '--ref', 'jms', '-f', "source_commit=$SourceCommit")
if ($NativeRunId) { $dispatch += @('-f', "native_run_id=$NativeRunId") }
& rtk proxy $githubCli @dispatch
if ($LASTEXITCODE) { throw 'Flatpak workflow dispatch failed' }
Write-Output "Flatpak CI dispatched for App source $SourceCommit with native run $NativeRunId; this does not publish a Release."
