$ErrorActionPreference = "Stop"
$env:PYTHONUTF8 = "1"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Invoke-Checked([string]$label, [scriptblock]$command) {
    Write-Host $label
    & $command
    if ($LASTEXITCODE -ne 0) { throw "$label failed with exit code $LASTEXITCODE" }
}

Write-Host "=== DK LOCK V2 RELEASE GATE ==="
Invoke-Checked "[1/10] V2 static architecture/integration validation" { python .\tests\validate_v2.py }
Invoke-Checked "[2/10] V0 regression" { python .\tests\validate_v0.py }
Invoke-Checked "[3/10] V1 regression adapter" { python .\tests\validate_v1_regression.py }
Invoke-Checked "[4/10] dotnet restore" { dotnet restore .\DKLock.sln }
Invoke-Checked "[5/10] dotnet build Release" { dotnet build .\DKLock.sln -c Release --no-restore }
Invoke-Checked "[6/10] V1 contract regression" { dotnet run --project .\tests\DKLock.V1.ContractTests\DKLock.V1.ContractTests.csproj -c Release --no-build }
Invoke-Checked "[7/10] V2 contract tests" { dotnet run --project .\tests\DKLock.V2.ContractTests\DKLock.V2.ContractTests.csproj -c Release --no-build }
Invoke-Checked "[8/10] V2 SQLite + IPC integration tests" { dotnet run --project .\tests\DKLock.V2.IntegrationTests\DKLock.V2.IntegrationTests.csproj -c Release --no-build }

Write-Host "[9/10] Actual service process + WPF online smoke"
$pipeName = "DKLock.V2.CI.$([guid]::NewGuid().ToString('N'))"
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$tempRoot = Join-Path $tempBase "dklock-v2-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$dbPath = Join-Path $tempRoot "dklock-v2-ci.db"
$env:DKLOCK_PIPE_NAME = $pipeName
$env:DKLOCK_DB_PATH = $dbPath
$env:DKLOCK_ALLOW_TEST_SHUTDOWN = "1"
$service = Join-Path $root "src\DKLock.Service\bin\Release\net8.0\DKLock.Service.exe"
$app = Join-Path $root "src\DKLock.App\bin\Release\net8.0-windows\DKLock.exe"
if (-not (Test-Path $service)) { throw "Service executable missing: $service" }
if (-not (Test-Path $app)) { throw "App executable missing: $app" }
$serviceProcess = Start-Process -FilePath $service -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Milliseconds 400
    if ($serviceProcess.HasExited) { throw "Service exited prematurely with code $($serviceProcess.ExitCode)" }
    $appProcess = Start-Process -FilePath $app -ArgumentList "--smoke-test" -Wait -PassThru
    if ($appProcess.ExitCode -ne 0) { throw "Online WPF smoke failed: $($appProcess.ExitCode)" }

    & dotnet run --project .\tests\DKLock.V2.IntegrationTests\DKLock.V2.IntegrationTests.csproj -c Release --no-build -- shutdown $pipeName
    if ($LASTEXITCODE -ne 0) { throw "Graceful service shutdown command failed with exit code $LASTEXITCODE" }
    if (-not $serviceProcess.WaitForExit(5000)) { throw "Service did not exit gracefully after IPC shutdown" }
    if ($serviceProcess.ExitCode -ne 0) { throw "Service exited with code $($serviceProcess.ExitCode)" }
} finally {
    if (-not $serviceProcess.HasExited) { Stop-Process -Id $serviceProcess.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host "[10/10] WPF offline/fail-safe smoke"
$offlinePipe = "DKLock.V2.Offline.$([guid]::NewGuid().ToString('N'))"
$env:DKLOCK_PIPE_NAME = $offlinePipe
$offlineProcess = Start-Process -FilePath $app -ArgumentList "--offline-smoke-test" -Wait -PassThru
if ($offlineProcess.ExitCode -ne 0) { throw "Offline WPF smoke failed: $($offlineProcess.ExitCode)" }

$onlineReport = Join-Path $root "report\runtime\V2_WPF_SMOKE_ONLINE.txt"
$onlinePng = Join-Path $root "report\runtime\V2_WPF_SMOKE_ONLINE.png"
$offlineReport = Join-Path $root "report\runtime\V2_WPF_SMOKE_OFFLINE.txt"
$offlinePng = Join-Path $root "report\runtime\V2_WPF_SMOKE_OFFLINE.png"
foreach ($f in @($onlineReport,$onlinePng,$offlineReport,$offlinePng)) { if (-not (Test-Path $f)) { throw "Missing runtime evidence: $f" } }
foreach ($f in @($onlineReport,$offlineReport)) { if (-not (Select-String -Path $f -Pattern "RESULT: PASS" -Quiet)) { throw "Runtime report failed: $f" } }

Write-Host "=== ALL DK LOCK V2 AUTOMATED RELEASE GATES PASS ==="
