param(
    [ValidateSet('release', 'profile', 'debug')][string]$Mode = 'release',
    [string]$Version = '',
    [int]$VersionCode = 0,
    [switch]$ProductionSigning,
    [switch]$UnsignedCandidate,
    [string]$SourceCommit = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')

function Assert-JmsUnsignedApk([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if (-not $archive.GetEntry('AndroidManifest.xml') -or -not $archive.GetEntry('lib/arm64-v8a/libapp.so')) {
            throw 'Unsigned candidate is not an ARM64 application APK'
        }
        if (@($archive.Entries | Where-Object { $_.FullName -match '^META-INF/[^/]+\.(SF|RSA|DSA|EC)$' }).Count) {
            throw 'Unsigned candidate contains a JAR signature'
        }
    } finally { $archive.Dispose() }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $length = [int][Math]::Min(65557, $stream.Length)
        $tail = New-Object byte[] $length
        $stream.Position = $stream.Length - $length
        if ($stream.Read($tail, 0, $length) -ne $length) { throw 'Incomplete APK ZIP trailer' }
        $end = -1
        for ($i = $length - 22; $i -ge 0; $i--) {
            if ([BitConverter]::ToUInt32($tail, $i) -eq 0x06054b50 -and
                $i + 22 + [BitConverter]::ToUInt16($tail, $i + 20) -eq $length) { $end = $i; break }
        }
        if ($end -lt 0) { throw 'APK ZIP trailer is missing' }
        $centralDirectory = [BitConverter]::ToUInt32($tail, $end + 16)
        if ($centralDirectory -eq [uint32]::MaxValue -or $centralDirectory -gt $stream.Length) { throw 'Unsupported APK ZIP directory' }
        if ($centralDirectory -ge 16) {
            $magic = New-Object byte[] 16
            $stream.Position = $centralDirectory - 16
            if ($stream.Read($magic, 0, 16) -ne 16) { throw 'Incomplete APK signing-block trailer' }
            if ([Text.Encoding]::ASCII.GetString($magic) -eq 'APK Sig Block 42') {
                throw 'Unsigned candidate contains an APK signing block'
            }
        }
    } finally { $stream.Dispose() }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
if ($UnsignedCandidate) {
    if ($ProductionSigning) { throw 'UnsignedCandidate conflicts with ProductionSigning' }
    if ($Mode -ne 'release') { throw 'Unsigned candidates require release mode' }
    if ($SourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Unsigned candidates require an explicit full SourceCommit' }
    foreach ($localPath in @('android/app/key.properties', 'android/app/keystore.jks', 'build/app', 'android/app/build', 'android/.gradle')) {
        if (Test-Path -LiteralPath (Join-Path $projectRoot $localPath)) {
            throw "Unsigned candidates require a fresh isolated checkout without $localPath"
        }
    }
}
$previousUnsignedMode = $env:JMS_UNSIGNED_CANDIDATE
$previousTestSigning = $env:JMS_TEST_SIGNING
try {
    $env:JMS_UNSIGNED_CANDIDATE = if ($UnsignedCandidate) { 'true' } else { 'false' }
    $projectVersion = [regex]::Match((Get-Content -LiteralPath 'pubspec.yaml' -Raw), '(?m)^version:\s*([^\s+]+)\+(\d+)\s*$')
    if (-not $projectVersion.Success) { throw 'pubspec.yaml must declare versionName+versionCode' }
    if ([string]::IsNullOrEmpty($Version)) { $Version = $projectVersion.Groups[1].Value }
    if ($VersionCode -eq 0) { $VersionCode = [int]$projectVersion.Groups[2].Value }
    $signingLabel = if ($UnsignedCandidate) { 'unsigned-candidate' } elseif ($ProductionSigning) { 'production-signed' } else { 'test-signed' }
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
    if ($UnsignedCandidate -or $ProductionSigning) {
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
        Where-Object { $_ -match '^(lib/|assets/|icons/|android/|third_party/|vendor/|config/(config|jms_updates)\.json$|pubspec\.yaml$|pubspec\.lock$|l10n\.yaml$|scripts/build_jms_android\.ps1$)' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object -Unique
    $inputs = @($inputPaths | ForEach-Object {
        [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $fingerprint = "$Version+$VersionCode/$Mode`n" + (($inputs | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n")
    if ($UnsignedCandidate) { $fingerprint = "unsigned-candidate`n$fingerprint" }
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprint))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $buildId = "JMS-$Version-$($digest.Substring(0, 12))"
    New-Item -ItemType Directory -Force 'artifacts/checks' | Out-Null
    $workspaceCommit = (& rtk proxy git rev-parse HEAD)
    if ($SourceCommit -ne '') {
        & rtk proxy (Join-Path $projectRoot '.jms-tools/python/Scripts/python.exe') scripts/jms_git_release.py --verify-commit $SourceCommit
        if ($LASTEXITCODE -ne 0) { throw 'Release build requires a clean jms commit' }
        if ($SourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid source snapshot commit' }
        & rtk proxy (Join-Path $projectRoot '.jms-tools/python/Scripts/python.exe') scripts/verify_jms_snapshot.py --commit $SourceCommit
        if ($LASTEXITCODE -ne 0) { throw 'Source snapshot does not match actual build inputs' }
    } else { $SourceCommit = $workspaceCommit }
    $record = [ordered]@{ buildId = $buildId; version = $Version; baseVersionCode = $VersionCode; mode = $Mode; sourceCommit = $SourceCommit; workspaceCommit = $workspaceCommit; gitSourceVerified = ($PSBoundParameters.ContainsKey('SourceCommit')); publicationSnapshot = ($PSBoundParameters.ContainsKey('SourceCommit')); inputs = $inputs }
    $recordPath = "artifacts/checks/build-$Version-inputs.json"
    if ($UnsignedCandidate) {
        $record.signing = 'none'
        $record.unsignedCandidate = $true
        $record.publishable = $false
        $recordPath = "artifacts/checks/build-$Version-unsigned-candidate-inputs.json"
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    Write-Output "Build ID: $buildId"
    & rtk proxy $flutterPath build apk "--$Mode" --flavor production "--build-name=$Version" "--build-number=$VersionCode" "--dart-define=JMS_BUILD_ID=$buildId" "--dart-define=JMS_SOURCE_COMMIT=$SourceCommit" "--dart-define=JMS_UPDATE_OWNER=$($updateSource.owner)" "--dart-define=JMS_UPDATE_REPO=$($updateSource.repo)" --target-platform android-arm64 --split-per-abi --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed' }
    $builtApk = Join-Path $projectRoot "build/app/outputs/flutter-apk/app-arm64-v8a-production-$Mode.apk"
    if ($UnsignedCandidate) { Assert-JmsUnsignedApk $builtApk }
    foreach ($inputFile in $inputs) {
        if ((Get-FileHash -LiteralPath $inputFile.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $inputFile.sha256) {
            throw "Build input changed during compilation: $($inputFile.path)"
        }
    }
    New-Item -ItemType Directory -Force (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $builtApk -Destination $destination
    if ($UnsignedCandidate) { Write-Output 'UNSIGNED CANDIDATE ONLY: not installable as an update and not publishable.' }
    Get-FileHash -LiteralPath $destination -Algorithm SHA256
} finally {
    $env:JMS_UNSIGNED_CANDIDATE = $previousUnsignedMode
    $env:JMS_TEST_SIGNING = $previousTestSigning
}
