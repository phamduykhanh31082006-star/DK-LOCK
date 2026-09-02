param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$script = Join-Path $Root 'scripts/test-v8.ps1'
if (-not (Test-Path $script)) { throw "V8 test script not found: $script" }

$content = Get-Content $script -Raw
$content = $content.Replace('for $language: $($setupUi.ExitCode)', 'for ${language}: $($setupUi.ExitCode)')
$content = $content.Replace('for $language: $($ui.ExitCode)', 'for ${language}: $($ui.ExitCode)')
Set-Content -Path $script -Value $content -Encoding utf8

$verified = Get-Content $script -Raw
if ($verified.Contains('for $language:')) { throw 'V8 parser fix did not remove all ambiguous language variable references.' }
Write-Host 'Applied V8 PowerShell parser fix for localized smoke-test diagnostics.'
