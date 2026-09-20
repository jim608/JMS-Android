param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Label,
    [ValidatePattern('^[a-zA-Z0-9_.]+$')][string]$PackageId = 'com.jim608.jms',
    [int]$WarmupSeconds = 120,
    [int]$DurationSeconds = 180
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$adbPath = Join-Path $projectRoot '.jms-tools\android-sdk\platform-tools\adb.exe'
$outputPath = Join-Path $projectRoot "artifacts\device\$Label"
if ((& $adbPath -s $Serial get-state 2>$null) -ne 'device') { throw 'BLOCKED: authorized Android device unavailable' }
if ((& $adbPath -s $Serial shell getprop ro.kernel.qemu).Trim() -eq '1') { throw 'BLOCKED: emulator cannot establish physical-device performance' }
$appProcess = (& $adbPath -s $Serial shell pidof $packageId).Trim()
if (-not $appProcess) { throw 'Start JMS and the specified test clip before measuring' }
New-Item -ItemType Directory -Force $outputPath | Out-Null
& $adbPath -s $Serial shell getprop ro.product.model > "$outputPath\device-model.txt"
& $adbPath -s $Serial shell getprop ro.build.version.release > "$outputPath\android-version.txt"
& $adbPath -s $Serial shell dumpsys package $packageId | Select-String 'versionName=|versionCode=' > "$outputPath\app-version.txt"
Write-Output "Warmup $WarmupSeconds seconds. Keep the specified clip, tracks and effect state fixed."
for ($elapsed = 0; $elapsed -lt $WarmupSeconds; $elapsed += 10) { Start-Sleep -Seconds ([Math]::Min(10, $WarmupSeconds - $elapsed)) }
& $adbPath -s $Serial shell dumpsys gfxinfo $packageId reset > "$outputPath\gfx-reset.txt"
& $adbPath -s $Serial shell dumpsys battery > "$outputPath\battery-start.txt"
& $adbPath -s $Serial shell dumpsys thermalservice > "$outputPath\thermal-start.txt"
$measurement = [Diagnostics.Stopwatch]::StartNew()
while ($measurement.Elapsed.TotalSeconds -lt $DurationSeconds) {
    $elapsed = [int]$measurement.Elapsed.TotalSeconds
    & $adbPath -s $Serial shell dumpsys meminfo $packageId > "$outputPath\memory-$elapsed.txt"
    & $adbPath -s $Serial shell top -b -n 1 -p $appProcess > "$outputPath\cpu-$elapsed.txt"
    $remaining = $DurationSeconds - $measurement.Elapsed.TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int](1000 * [Math]::Min(10, $remaining))) }
}
& $adbPath -s $Serial shell dumpsys gfxinfo $packageId framestats > "$outputPath\android-frames.txt"
& $adbPath -s $Serial shell dumpsys battery > "$outputPath\battery-end.txt"
& $adbPath -s $Serial shell dumpsys thermalservice > "$outputPath\thermal-end.txt"
Write-Output 'Captured Android window/CPU/memory/thermal data. Flutter UI/raster timings require a separate profile-mode DevTools trace. Video dropped frames, GPU and A/V sync are not inferred from gfxinfo.'
