$ErrorActionPreference = "Stop"
$env:PYTHONUTF8 = "1"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Invoke-Checked([string]$label, [scriptblock]$command) {
    Write-Host $label
    & $command
    if ($LASTEXITCODE -ne 0) { throw "$label failed with exit code $LASTEXITCODE" }
}

Write-Host "=== DK LOCK V3 RELEASE GATE ==="
Invoke-Checked "[1/15] V3 static architecture/security/UX validation" { python .\tests\validate_v3.py }
Invoke-Checked "[2/15] V0 regression" { python .\tests\validate_v0.py }
Invoke-Checked "[3/15] V1 regression" { python .\tests\validate_v1_regression.py }
Invoke-Checked "[4/15] V2 regression" { python .\tests\validate_v2_regression.py }
Invoke-Checked "[5/15] restore production solution" { dotnet restore .\DKLock.sln }
Write-Host "[6/15] restore V3 tests"
Invoke-Checked "  - restore V3 contract tests" { dotnet restore .\tests\DKLock.V3.ContractTests\DKLock.V3.ContractTests.csproj }
Invoke-Checked "  - restore V3 integration tests" { dotnet restore .\tests\DKLock.V3.IntegrationTests\DKLock.V3.IntegrationTests.csproj }
Invoke-Checked "[7/15] build production Release" { dotnet build .\DKLock.sln -c Release --no-restore }
Write-Host "[8/15] build V3 test suite Release"
Invoke-Checked "  - build V3 contract tests" { dotnet build .\tests\DKLock.V3.ContractTests\DKLock.V3.ContractTests.csproj -c Release --no-restore }
Invoke-Checked "  - build V3 integration tests" { dotnet build .\tests\DKLock.V3.IntegrationTests\DKLock.V3.IntegrationTests.csproj -c Release --no-restore }
Invoke-Checked "[9/15] V1 contract regression" { dotnet run --project .\tests\DKLock.V1.ContractTests\DKLock.V1.ContractTests.csproj -c Release --no-build }
Invoke-Checked "[10/15] V2 contract regression" { dotnet run --project .\tests\DKLock.V2.ContractTests\DKLock.V2.ContractTests.csproj -c Release --no-build }
Invoke-Checked "[11/15] V2 integration compatibility" { dotnet run --project .\tests\DKLock.V2.IntegrationTests\DKLock.V2.IntegrationTests.csproj -c Release --no-build }
Invoke-Checked "[12/15] V3 contract/security tests" { dotnet run --project .\tests\DKLock.V3.ContractTests\DKLock.V3.ContractTests.csproj -c Release --no-build }
Invoke-Checked "[13/15] V3 real-process integration/E2E" { dotnet run --project .\tests\DKLock.V3.IntegrationTests\DKLock.V3.IntegrationTests.csproj -c Release --no-build }

Write-Host "[14/15] Actual DKLock.Service process + WPF V3 online/UI smoke"
$pipeName = "DKLock.V3.CI.$([guid]::NewGuid().ToString('N'))"
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$tempRoot = Join-Path $tempBase "dklock-v3-wpf-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$env:DKLOCK_PIPE_NAME = $pipeName
$env:DKLOCK_DB_PATH = Join-Path $tempRoot "dklock-v3-wpf.db"
$env:DKLOCK_ALLOW_TEST_SHUTDOWN = "1"
$service = Join-Path $root "src\DKLock.Service\bin\Release\net8.0\DKLock.Service.exe"
$app = Join-Path $root "src\DKLock.App\bin\Release\net8.0-windows\DKLock.exe"
if (-not (Test-Path $service)) { throw "Service executable missing: $service" }
if (-not (Test-Path $app)) { throw "App executable missing: $app" }
$serviceProcess = Start-Process -FilePath $service -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Milliseconds 800
    if ($serviceProcess.HasExited) { throw "Service exited prematurely with code $($serviceProcess.ExitCode)" }
    $online = Start-Process -FilePath $app -ArgumentList "--smoke-test" -Wait -PassThru
    if ($online.ExitCode -ne 0) { throw "V3 online WPF smoke failed: $($online.ExitCode)" }
    $ui = Start-Process -FilePath $app -ArgumentList "--v3-ui-smoke-test" -Wait -PassThru
    if ($ui.ExitCode -ne 0) { throw "V3 application/unlock UI smoke failed: $($ui.ExitCode)" }
    & dotnet run --project .\tests\DKLock.V2.IntegrationTests\DKLock.V2.IntegrationTests.csproj -c Release --no-build -- shutdown $pipeName
    if ($LASTEXITCODE -ne 0) { throw "Graceful service shutdown failed" }
    if (-not $serviceProcess.WaitForExit(5000)) { throw "Service did not stop after IPC shutdown" }
} finally {
    if (-not $serviceProcess.HasExited) { Stop-Process -Id $serviceProcess.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host "[15/15] WPF V3 offline/fail-safe smoke + evidence verification"
$env:DKLOCK_PIPE_NAME = "DKLock.V3.Offline.$([guid]::NewGuid().ToString('N'))"
$offline = Start-Process -FilePath $app -ArgumentList "--offline-smoke-test" -Wait -PassThru
if ($offline.ExitCode -ne 0) { throw "V3 offline WPF smoke failed: $($offline.ExitCode)" }
$evidence = @(
    "report\runtime\V3_WPF_SMOKE_ONLINE.txt", "report\runtime\V3_WPF_SMOKE_ONLINE.png",
    "report\runtime\V3_WPF_SMOKE_OFFLINE.txt", "report\runtime\V3_WPF_SMOKE_OFFLINE.png",
    "report\runtime\V3_APPLICATIONS_UI.txt", "report\runtime\V3_APPLICATIONS_UI.png", "report\runtime\V3_UNLOCK_UI.png"
)
foreach ($file in $evidence) { if (-not (Test-Path $file)) { throw "Missing V3 runtime evidence: $file" } }
foreach ($file in @("report\runtime\V3_WPF_SMOKE_ONLINE.txt","report\runtime\V3_WPF_SMOKE_OFFLINE.txt","report\runtime\V3_APPLICATIONS_UI.txt")) {
    if (-not (Select-String -Path $file -Pattern "RESULT: PASS" -Quiet)) { throw "Runtime evidence reports failure: $file" }
}
Write-Host "=== ALL DK LOCK V3 AUTOMATED RELEASE GATES PASS ==="
