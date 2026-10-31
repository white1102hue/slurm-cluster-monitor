param([switch]$Build)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
Push-Location $taskRoot
try {
    $taskFlutter = Join-Path $taskRoot '.tooling/flutter/bin/flutter.bat'
    if (-not (Test-Path -LiteralPath $taskFlutter)) {
        $taskFlutter = (Get-Command flutter -ErrorAction Stop).Source
    }
    $taskJdk = Join-Path $taskRoot '.tooling/jdk'
    $taskSdk = Join-Path $taskRoot '.tooling/android-sdk'
    if (Test-Path -LiteralPath $taskJdk) { $env:JAVA_HOME = $taskJdk }
    if (Test-Path -LiteralPath $taskSdk) { $env:ANDROID_HOME = $taskSdk; $env:ANDROID_SDK_ROOT = $taskSdk }
    & $taskFlutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    & $taskFlutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
    $taskTestArgs = @('test')
    if ($env:SLURM_SSH_FIXTURE) { $taskTestArgs += '--concurrency=1' }
    & $taskFlutter @taskTestArgs
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    if ($Build) {
        & $taskFlutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw 'APK build failed' }
    }
} finally { Pop-Location }
