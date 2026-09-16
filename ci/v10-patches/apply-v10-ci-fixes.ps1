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
    if ($agentText -notmatch '(?m)^using\s+') { throw 'Protection agent has no using directive anchor.' }
    $agentText = "using System.IO;`r`n" + $agentText
    Set-Content -Path $agent -Value $agentText -Encoding utf8
}

$assetCarrier = Join-Path $PSScriptRoot 'v10-ci-assets.b64'
if (-not (Test-Path $assetCarrier)) { throw "Missing V10 test/release asset carrier: $assetCarrier" }
$assetArchive = Join-Path $env:RUNNER_TEMP 'v10-ci-assets.tar.xz'
$assetB64 = (Get-Content $assetCarrier -Raw).Trim()
[IO.File]::WriteAllBytes($assetArchive, [Convert]::FromBase64String($assetB64))
$assetHash = (Get-FileHash $assetArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($assetHash -ne '72bfef81ed50ca736573b0222a8c5acfb26432f17bdc0110fea289302706370e') { throw "V10 test/release asset SHA mismatch: $assetHash" }
tar -xf $assetArchive -C $Root
if ($LASTEXITCODE -ne 0) { throw 'Failed to extract V10 test/release asset bundle.' }
foreach ($required in @(
    'scripts/test-v10.ps1',
    'scripts/build-v10-release.ps1',
    'tests/validate_v10.py',
    'tests/DKLock.V10.ContractTests/DKLock.V10.ContractTests.csproj',
    'tests/DKLock.V10.ContractTests/Program.cs',
    'tools/DKLock.V10.Probe/DKLock.V10.Probe.csproj',
    'tools/DKLock.V10.Probe/Program.cs',
    'V10_SCOPE.md'
)) {
    if (-not (Test-Path (Join-Path $Root $required))) { throw "V10 required production asset missing after extraction: $required" }
}

Write-Host "Applied V10 CI fixes and verified production asset bundle SHA256=$assetHash"
