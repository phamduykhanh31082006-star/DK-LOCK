param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'

$overlay = Join-Path $Root 'src/DKLock.App/Protection/ApplicationLockOverlayWindow.xaml'
if (-not (Test-Path $overlay)) { throw "Missing V10 overlay: $overlay" }
$text = Get-Content $overlay -Raw
$needle = '<Grid Background="{DynamicResource Brush.Window}">'
if ($text -notlike "*$needle*") { throw 'Expected V10 overlay Grid background marker is missing.' }
$text = $text.Replace($needle, '<Grid>')
Set-Content -Path $overlay -Value $text -Encoding utf8

$agent = Join-Path $Root 'src/DKLock.App/Protection/ApplicationWindowProtectionAgent.cs'
if (-not (Test-Path $agent)) { throw "Missing V10 protection agent: $agent" }
$agentText = Get-Content $agent -Raw
if ($agentText -notmatch '(?m)^using System\.IO;\s*$') {
    if ($agentText -notmatch '(?m)^using System;\s*$') { throw 'Expected System using marker missing from protection agent.' }
    $agentText = $agentText -replace '(?m)^using System;\s*$', "using System;`r`nusing System.IO;"
    Set-Content -Path $agent -Value $agentText -Encoding utf8
}

Write-Host 'Applied V10 CI fixes: overlay XAML background and System.IO import.'
