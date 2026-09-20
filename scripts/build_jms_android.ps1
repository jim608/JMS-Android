param(
    [ValidateSet('release', 'profile', 'debug')][string]$Mode = 'release',
    [string]$Version = '',
    [int]$VersionCode = 0,
    [switch]$ProductionSigning,
    [string]$SourceCommit = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$projectVersion = [regex]::Match((Get-Content -LiteralPath 'pubspec.yaml' -Raw), '(?m)^version:\s*([^\s+]+)\+(\d+)\s*$')
if (-not $projectVersion.Success) { throw 'pubspec.yaml must declare versionName+versionCode' }
if ([string]::IsNullOrEmpty($Version)) { $Version = $projectVersion.Groups[1].Value }
if ($VersionCode -eq 0) { $VersionCode = [int]$projectVersion.Groups[2].Value }
$signingLabel = if ($ProductionSigning) { 'production-signed' } else { 'test-signed' }
$destination = Join-Path $projectRoot "artifacts\JMS-Android-$Version-$Mode-arm64-$signingLabel.apk"
if (Test-Path -LiteralPath $destination) { throw 'This APK version already exists; refusing to overwrite a delivered build' }
$flutterPath = Join-Path $projectRoot '.jms-tools\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterPath)) { throw 'Flutter 3.35.7 is required in .jms-tools/flutter' }
$env:ANDROID_HOME = Join-Path $projectRoot '.jms-tools\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$updateSource = Get-Content -LiteralPath 'config/jms_updates.json' -Raw | ConvertFrom-Json
if (($updateSource.owner -ne '') -or ($updateSource.repo -ne '')) {
    if ($updateSource.owner -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$' -or $updateSource.repo -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$' -or "$($updateSource.owner)/$($updateSource.repo)" -ieq 'DonutWare/Fladder') {
        throw 'Invalid or upstream update source; use only the user-confirmed public JMS repository'
    }
}
if ($ProductionSigning) {
    Remove-Item Env:JMS_TEST_SIGNING -ErrorAction SilentlyContinue
} else {
    if (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.android/debug.keystore'))) {
        throw 'Existing JMS test keystore missing; refusing automatic key generation'
    }
    $env:JMS_TEST_SIGNING = 'true'
}
& rtk proxy $flutterPath pub get --enforce-lockfile
if ($LASTEXITCODE -ne 0) { throw 'Dependency lock validation failed' }
& rtk proxy $flutterPath gen-l10n
if ($LASTEXITCODE -ne 0) { throw 'Localization generation failed' }
$inputPaths = @(& rtk proxy git ls-files --cached --others --exclude-standard) |
    Where-Object { $_ -match '^(lib/|assets/|icons/|android/|third_party/|config/(config|jms_updates)\.json$|pubspec\.yaml$|pubspec\.lock$|l10n\.yaml$|scripts/build_jms_android\.ps1$)' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object -Unique
$inputs = @($inputPaths | ForEach-Object {
    [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$fingerprint = "$Version+$VersionCode/$Mode`n" + (($inputs | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n")
$hasher = [System.Security.Cryptography.SHA256]::Create()
try { $digest = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprint))).Replace('-', '').ToLowerInvariant() }
finally { $hasher.Dispose() }
$buildId = "JMS-$Version-$($digest.Substring(0, 12))"
New-Item -ItemType Directory -Force 'artifacts/checks' | Out-Null
$workspaceCommit = (& rtk proxy git rev-parse HEAD)
if ($SourceCommit -ne '') {
    if ($SourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid source snapshot commit' }
    & rtk proxy (Join-Path $projectRoot '.jms-tools/python/Scripts/python.exe') scripts/verify_jms_snapshot.py --commit $SourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'Source snapshot does not match actual build inputs' }
} else { $SourceCommit = $workspaceCommit }
$record = [ordered]@{ buildId = $buildId; version = $Version; baseVersionCode = $VersionCode; mode = $Mode; sourceCommit = $SourceCommit; workspaceCommit = $workspaceCommit; publicationSnapshot = ($SourceCommit -ne $workspaceCommit); inputs = $inputs }
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "artifacts/checks/build-$Version-inputs.json" -Encoding UTF8
Write-Output "Build ID: $buildId"
& rtk proxy $flutterPath build apk "--$Mode" --flavor production "--build-name=$Version" "--build-number=$VersionCode" "--dart-define=JMS_BUILD_ID=$buildId" "--dart-define=JMS_UPDATE_OWNER=$($updateSource.owner)" "--dart-define=JMS_UPDATE_REPO=$($updateSource.repo)" --target-platform android-arm64 --split-per-abi --no-pub
if ($LASTEXITCODE -ne 0) { throw 'APK build failed' }
foreach ($inputFile in $inputs) {
    if ((Get-FileHash -LiteralPath $inputFile.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $inputFile.sha256) {
        throw "Build input changed during compilation: $($inputFile.path)"
    }
}
$signingLabel = if ($ProductionSigning) { 'production-signed' } else { 'test-signed' }
$destination = Join-Path $projectRoot "artifacts\JMS-Android-$Version-$Mode-arm64-$signingLabel.apk"
New-Item -ItemType Directory -Force (Split-Path -Parent $destination) | Out-Null
Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-arm64-v8a-production-$Mode.apk" -Destination $destination
Get-FileHash -LiteralPath $destination -Algorithm SHA256
