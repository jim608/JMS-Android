param([Parameter(Mandatory = $true)][string]$SourceCommit)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
$python = Join-Path $root '.jms-tools/python/Scripts/python.exe'
& rtk proxy $python scripts/verify_jms_snapshot.py --commit $SourceCommit
if ($LASTEXITCODE) { throw 'Source snapshot differs; refusing Linux release build' }
& rtk proxy $python scripts/check_jms_git_privacy.py --tree $SourceCommit
if ($LASTEXITCODE) { throw 'Source privacy gate failed' }
$match = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*([^+\s]+)\+(\d+)')
$version = $match.Groups[1].Value
$buildId = "JMS-$version-linux-$($SourceCommit.Substring(0,12))"
$output = Join-Path $root "artifacts/linux/$version"
if (Test-Path -LiteralPath $output) { throw 'Linux output already exists; refusing replacement' }
New-Item -ItemType Directory -Path $output | Out-Null
$context = Join-Path $output 'context'
New-Item -ItemType Directory -Path $context | Out-Null
& rtk proxy git archive --format=tar "--output=$output/source.tar" $SourceCommit
if ($LASTEXITCODE) { throw 'Source export failed' }
& rtk proxy tar -xf "$output/source.tar" -C $context
if ($LASTEXITCODE) { throw 'Source extraction failed' }
$image = "jms-linux-build:$version"
& rtk proxy docker build --target package -f "$context/Dockerfile.linux" --build-arg "JMS_BUILD_ID=$buildId" --build-arg "JMS_SOURCE_COMMIT=$SourceCommit" -t $image $context
if ($LASTEXITCODE) { throw 'Linux build failed; retained context and old artifacts' }
$container = "jms-linux-export-$($SourceCommit.Substring(0,12))"
$ledger = Join-Path $output 'container-cleanup.json'
$cleanupExit = 0
try {
    $containerId = & rtk proxy $python scripts/jms_docker_cleanup.py --ledger $ledger create --image $image --purpose linux-package-export -- --name $container $image /bin/true
    if ($LASTEXITCODE -ne 0 -or $containerId -cnotmatch '^[a-f0-9]{64}$') { throw 'Export container creation failed; inspect cleanup evidence' }
    & rtk proxy docker cp "${containerId}:/output/." $output
    if ($LASTEXITCODE) { throw 'Linux artifact export failed' }
} finally {
    if (Test-Path -LiteralPath $ledger) {
        & rtk proxy $python scripts/jms_docker_cleanup.py --ledger $ledger cleanup
        $cleanupExit = $LASTEXITCODE
        if ($cleanupExit) { Write-Warning "Container cleanup incomplete; inspect $ledger. Running containers were not stopped." }
    }
}
if ($cleanupExit) { throw 'Linux container retirement requires attention; retained IDs and reasons are in cleanup receipt' }
Write-Output "Linux package prepared: $output; not published or installed"
