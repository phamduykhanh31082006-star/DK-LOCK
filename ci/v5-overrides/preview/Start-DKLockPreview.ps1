param([switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dataRoot = Join-Path $root 'data'
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$dbPath = Join-Path $dataRoot 'dklock-preview.db'
$pipeName = 'DKLock.Preview.' + $PID + '.' + [Guid]::NewGuid().ToString('N')

function Quote-ProcessArgument([string]$value) {
    if ($null -eq $value) { return '""' }
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$serviceInfo = New-Object System.Diagnostics.ProcessStartInfo
$serviceInfo.FileName = Join-Path $root 'service\DKLock.Service.exe'
$serviceInfo.UseShellExecute = $false
$serviceInfo.CreateNoWindow = $true
$serviceInfo.Arguments = '--pipe-name ' + (Quote-ProcessArgument $pipeName) + ' --db-path ' + (Quote-ProcessArgument $dbPath) + ' --allow-test-shutdown'
$service = [System.Diagnostics.Process]::Start($serviceInfo)
if ($null -eq $service) { throw 'Could not start DK LOCK preview service.' }

try {
    Start-Sleep -Milliseconds 700
    if ($service.HasExited) { throw "DK LOCK preview service exited early with code $($service.ExitCode)." }

    $appInfo = New-Object System.Diagnostics.ProcessStartInfo
    $appInfo.FileName = Join-Path $root 'app\DKLock.exe'
    $appInfo.UseShellExecute = $false
    $appInfo.EnvironmentVariables['DKLOCK_PIPE_NAME'] = $pipeName
    if ($SmokeTest) { $appInfo.Arguments = '--smoke-test' }
    $app = [System.Diagnostics.Process]::Start($appInfo)
    if ($null -eq $app) { throw 'Could not start DK LOCK preview app.' }
    $app.WaitForExit()
}
finally {
    try {
        $control = Join-Path $root 'control\DKLock.PreviewControl.exe'
        if (Test-Path $control) {
            & $control $pipeName | Out-Host
            $service.WaitForExit(5000) | Out-Null
        }
    } catch { Write-Warning $_ }
    if (-not $service.HasExited) { Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue }
}
