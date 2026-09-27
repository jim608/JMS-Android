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
& rtk proxy docker create --name $container $image /bin/true
if ($LASTEXITCODE) { throw 'Export container creation failed' }
& rtk proxy docker cp "${container}:/output/." $output
if ($LASTEXITCODE) { throw 'Linux artifact export failed' }
Write-Output "Linux package prepared: $output; not published or installed"
