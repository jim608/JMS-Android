param(
    [string]$SourceCommit = '',
    [string]$Version = '',
    [switch]$PortableOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $projectRoot

$versionMatch = [regex]::Match((Get-Content -LiteralPath 'pubspec.yaml' -Raw), '(?m)^version:\s*([^\s+]+)\+(\d+)\s*$')
if (-not $versionMatch.Success) { throw 'pubspec.yaml must declare versionName+versionCode' }
if (-not $Version) { $Version = $versionMatch.Groups[1].Value }
if ($Version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?$') { throw 'Invalid version' }
$versionCode = [int]$versionMatch.Groups[2].Value
$flutterPath = Join-Path $projectRoot '.jms-tools\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterPath)) { throw 'Pinned Flutter SDK is missing' }

if ($SourceCommit -ne '') {
    if ($SourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'SourceCommit must be a full lowercase Git SHA-1' }
    $pythonPath = Join-Path $projectRoot '.jms-tools\python\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonPath)) { throw 'Snapshot verifier Python is missing' }
    & rtk proxy $pythonPath 'scripts/verify_jms_snapshot.py' --commit $SourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'Source snapshot does not match the current worktree' }
    $sourceId = $SourceCommit.Substring(0, 12)
} else {
    $hashInputs = Get-ChildItem -LiteralPath lib,assets,windows -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]flutter[\\/]ephemeral[\\/]' } |
        Sort-Object FullName | Get-FileHash -Algorithm SHA256
    $fingerprint = ($hashInputs.Hash -join '') + (Get-FileHash pubspec.lock -Algorithm SHA256).Hash
    $digest = [System.Security.Cryptography.SHA256]::Create()
    try { $sourceId = 'local-' + ([BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprint))).Replace('-', '').Substring(0,12).ToLowerInvariant()) }
    finally { $digest.Dispose() }
}
$buildId = "JMS-$version-windows-$sourceId"
$artifactDir = Join-Path $projectRoot "artifacts\windows\$version"
$bundleDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$stageDir = Join-Path $artifactDir "JMS-Windows-$version-x64"
$zipPath = Join-Path $artifactDir "JMS-Windows-$version-x64-portable.zip"
$setupBase = "JMS-Windows-$version-x64-setup"
$setupPath = Join-Path $artifactDir "$setupBase.exe"
if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $stageDir) -or (Test-Path -LiteralPath $setupPath)) {
    throw 'Windows artifact for this version already exists; refusing to overwrite it'
}

$vswherePath = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswherePath)) {
    throw 'Visual Studio with the Desktop development with C++ workload is required'
}
$visualStudio = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($visualStudio)) {
    throw 'Visual Studio C++ x64 tools are missing'
}

$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
& rtk proxy $flutterPath pub get --enforce-lockfile
if ($LASTEXITCODE -ne 0) { throw 'Dependency lock validation failed' }
& rtk proxy $flutterPath build windows --release --no-pub "--build-name=$version" "--build-number=$versionCode" "--dart-define=JMS_BUILD_ID=$buildId"
if ($LASTEXITCODE -ne 0) { throw 'Windows x64 build failed' }

foreach ($required in @('jms.exe', 'flutter_windows.dll', 'data\flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundleDir $required))) {
        throw "Windows build bundle is incomplete: $required"
    }
}

New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
Get-ChildItem -LiteralPath $bundleDir -Force | Copy-Item -Destination $stageDir -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $stageDir 'LICENSE')
$licenseDir = Join-Path $stageDir 'licenses'
New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\fvp\LICENSE') -Destination (Join-Path $licenseDir 'fvp-LICENSE.txt')

$buildInfo = [ordered]@{
    application = 'JMS'
    version = $version
    versionCode = $versionCode
    buildId = $buildId
    platform = 'windows-x64'
    sourceCommit = $SourceCommit
    signing = 'unsigned'
}
$buildInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stageDir 'JMS_BUILD_INFO.json') -Encoding UTF8
Compress-Archive -LiteralPath $stageDir -DestinationPath $zipPath -CompressionLevel Optimal

if (-not $PortableOnly) {
    $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    if (-not $iscc) {
        foreach ($candidate in @((Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'), 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe', 'C:\Program Files\Inno Setup 6\ISCC.exe')) {
            if (Test-Path -LiteralPath $candidate) { $iscc = $candidate; break }
        }
    }
    if (-not $iscc) { throw "Portable ZIP is ready at $zipPath; Inno Setup 6 is required for the installer" }
    & rtk proxy $iscc "/DJMS_VERSION=$version" "/DJMS_BUNDLE=$stageDir" "/O$artifactDir" "/F$setupBase" 'windows/windows_setup.iss'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setupPath)) { throw 'Inno Setup installer build failed' }
}

$outputs = @($zipPath)
if (-not $PortableOnly) { $outputs += $setupPath }
$hashes = foreach ($output in $outputs) {
    [ordered]@{
        file = (Split-Path -Leaf $output)
        size = (Get-Item -LiteralPath $output).Length
        sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
([ordered]@{ build = $buildInfo; outputs = @($hashes) } | ConvertTo-Json -Depth 5) |
    Set-Content -LiteralPath (Join-Path $artifactDir 'build-manifest.json') -Encoding UTF8
Write-Output "Build ID: $buildId"
$hashes | Format-Table -AutoSize
