$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$taskRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$taskApk = Join-Path $taskRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (-not (Test-Path -LiteralPath $taskApk)) {
    throw 'Release APK missing. Run scripts/check.ps1 -Build before packaging.'
}
$taskVersion = [regex]::Match(
    (Get-Content -LiteralPath (Join-Path $taskRoot 'pubspec.yaml') -Raw),
    '(?m)^version:\s*(\S+)\+(\d+)\s*$'
)
$taskMetadata = Get-Content -LiteralPath (Join-Path $taskRoot 'build/app/outputs/apk/release/output-metadata.json') -Raw | ConvertFrom-Json
if (-not $taskVersion.Success -or
    $taskMetadata.elements[0].versionName -ne $taskVersion.Groups[1].Value -or
    $taskMetadata.elements[0].versionCode -ne [int]$taskVersion.Groups[2].Value) {
    throw 'Release APK version differs from pubspec.yaml. Rebuild before packaging.'
}
$taskOutput = Join-Path $taskRoot 'artifacts'
New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
$taskZipPath = Join-Path $taskOutput 'slurm_cluster_monitor_source.zip'
$taskStream = [IO.File]::Open($taskZipPath, [IO.FileMode]::Create)
$taskZip = [IO.Compression.ZipArchive]::new($taskStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    $allow = @('lib','android','web','test','tool','scripts','docs','README.md','CHANGELOG.md','pubspec.yaml','pubspec.lock','analysis_options.yaml','.metadata','.gitignore','.gitattributes')
    foreach ($entry in $allow) {
        $target = Join-Path $taskRoot $entry
        if (-not (Test-Path -LiteralPath $target)) { continue }
        $files = if ((Get-Item -LiteralPath $target).PSIsContainer) { Get-ChildItem -LiteralPath $target -Recurse -File -Force } else { Get-Item -LiteralPath $target }
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($taskRoot, $file.FullName).Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
            if ($relative -match '(^|/)(\.gradle|\.kotlin|\.idea|\.cxx|__pycache__|build)/' -or
                $relative -match '(^|/)(local\.properties|key\.properties|GeneratedPluginRegistrant\.java|connection\.json|state\.json|counters[^/]*\.json|last-command\.json|credentials\.json|secrets\.json)$' -or
                $relative -match '(^|/)\.env($|\.)' -or
                $relative -match '(^|/)id_(rsa|ed25519)[^/]*$' -or
                $relative -match '\.(jks|keystore|pem|key|p12|pfx|pub|log|iml|hprof|symbols|pdb|pyc|apk|aab|zip|bak|tmp)$') { continue }
            $zipEntry = $taskZip.CreateEntry("slurm_cluster_monitor/$relative", [IO.Compression.CompressionLevel]::Optimal)
            $taskInputStream = [IO.File]::OpenRead($file.FullName)
            $taskOutputStream = $zipEntry.Open()
            try { $taskInputStream.CopyTo($taskOutputStream) } finally { $taskInputStream.Dispose(); $taskOutputStream.Dispose() }
        }
    }
} finally { $taskZip.Dispose(); $taskStream.Dispose() }
Copy-Item -LiteralPath $taskApk -Destination (Join-Path $taskOutput 'slurm_cluster_monitor.apk') -Force
@('slurm_cluster_monitor.apk', 'slurm_cluster_monitor_source.zip') | ForEach-Object {
    $file = Get-Item -LiteralPath (Join-Path $taskOutput $_)
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower()
    "$hash  $($file.Name)"
} | Set-Content -LiteralPath (Join-Path $taskOutput 'SHA256SUMS.txt') -Encoding utf8
Write-Output $taskOutput
