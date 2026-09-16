param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'

$overlay = Join-Path $Root 'src/DKLock.App/Protection/ApplicationLockOverlayWindow.xaml'
if (-not (Test-Path $overlay)) { throw "Missing V10 overlay: $overlay" }
$text = Get-Content $overlay -Raw
$needle = '<Grid Background="{DynamicResource Brush.Window}">'
if ($text -notlike "*$needle*") { throw 'Expected V10 overlay Grid background marker is missing.' }
$text = $text.Replace($needle, '<Grid>')
Set-Content -Path $overlay -Value $text -Encoding utf8

Write-Host 'Applied V10 CI fixes: removed duplicate Grid.Background declaration.'
