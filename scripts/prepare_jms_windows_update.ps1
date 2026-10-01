param([Parameter(Mandatory = $true)][string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
$artifact = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$manifest = Get-Content -LiteralPath (Join-Path $artifact 'build-manifest.json') -Raw | ConvertFrom-Json
$build = $manifest.build
if ($build.platform -cne 'windows-x64' -or $build.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
    $build.privateConfiguration -ne $false) {
    throw 'A reviewed source-commit build is required; local dirty builds cannot become updates'
}
$python = Join-Path $root '.jms-tools/python/Scripts/python.exe'
& rtk proxy $python scripts/verify_jms_snapshot.py --commit $build.sourceCommit --recorded-windows-candidate (Join-Path $artifact 'build-manifest.json')
if ($LASTEXITCODE -ne 0) { throw 'Source snapshot mismatch' }
& rtk proxy $python scripts/check_jms_git_privacy.py --tree $build.sourceCommit
if ($LASTEXITCODE -ne 0) { throw 'Source privacy check failed' }
$setups = @($manifest.outputs | Where-Object { $_.file -cmatch '^JMS-Windows-[A-Za-z0-9._+-]+-x64-setup\.exe$' })
if ($setups.Count -ne 1) { throw 'Exactly one complete installer is required' }
$setup = $setups[0]
$installer = Join-Path $artifact $setup.file
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($installer)
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $installer).Length
if ($info.ProductName.Trim() -cne 'JMS' -or $info.ProductVersion.Trim() -cne $build.version -or
    $info.FilePrivatePart -ne $build.versionCode -or $hash -cne $setup.sha256 -or
    $size -ne $setup.size -or $size -gt 314572800 -or $size -le 0 -or
    (Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'NotSigned') {
    throw 'Actual installer metadata, size, hash or signing policy mismatch'
}
$sourceName = "JMS-Windows-$($build.version)-source.zip"
$source = Join-Path $artifact $sourceName
$update = Join-Path $artifact 'update.json'
if ((Test-Path -LiteralPath $source) -or (Test-Path -LiteralPath $update)) {
    throw 'Prepared materials already exist; refusing to replace them'
}
& rtk proxy $python scripts/package_jms_sources.py --commit $build.sourceCommit --output $source
if ($LASTEXITCODE -ne 0) { throw 'Source archive failed' }
$data = [ordered]@{
    schemaVersion = 1
    applicationId = 'com.jim608.jms'
    platform = 'windows-x64'
    versionName = $build.version
    versionCode = [int]$build.versionCode
    minWindowsBuild = 17763
    buildId = $build.buildId
    sourceCommit = $build.sourceCommit
    signing = 'unsigned'
    installer = @{ name = $setup.file; size = $size; sha256 = $hash }
    source = @{ name = $sourceName; size = (Get-Item -LiteralPath $source).Length;
        sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $update -Encoding utf8
@("$hash  $($setup.file)", "$($data.source.sha256)  $sourceName") |
    Set-Content -LiteralPath (Join-Path $artifact 'SHA256SUMS.txt') -Encoding ascii
Write-Output 'Local update metadata prepared. Publication still requires Windows native-source/license and release checks. Nothing uploaded.'
