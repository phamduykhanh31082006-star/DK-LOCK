param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'

# Apply the unified, locally validated V10 target override to the reconstructed candidate.
$targetParts = @(Get-ChildItem (Join-Path $PSScriptRoot 'target.part*') | Sort-Object Name)
if ($targetParts.Count -ne 6) { throw "Expected 6 V10 target override parts, found $($targetParts.Count)." }
$targetRaw = ($targetParts | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$targetArchive = Join-Path $tempRoot 'v10-target-override.tar.xz'
[IO.File]::WriteAllBytes($targetArchive, [Convert]::FromBase64String($targetRaw))
$targetHash = (Get-FileHash $targetArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedTargetHash = 'b10af234bf91325a6a38c643c0cca149da4db094ea8f140bc8d1bbcd1abb22df'
if ($targetHash -ne $expectedTargetHash) { throw "V10 target override SHA mismatch: $targetHash" }
tar -xf $targetArchive -C $Root
if ($LASTEXITCODE -ne 0) { throw 'Failed to extract V10 target override.' }
Remove-Item $targetArchive -Force -ErrorAction SilentlyContinue

# Deterministic compile repairs retained after the recovered candidate was reconstructed.
$overlay = Join-Path $Root 'src/DKLock.App/Protection/ApplicationLockOverlayWindow.xaml'
if (-not (Test-Path $overlay)) { throw "Missing V10 overlay: $overlay" }
$text = Get-Content $overlay -Raw
$needle = '<Grid Background="{DynamicResource Brush.Window}">'
if ($text -like "*$needle*") {
    $text = $text.Replace($needle, '<Grid>')
    Set-Content -Path $overlay -Value $text -Encoding utf8
}

$agent = Join-Path $Root 'src/DKLock.App/Protection/ApplicationWindowProtectionAgent.cs'
if (-not (Test-Path $agent)) { throw "Missing V10 protection agent: $agent" }
$agentText = Get-Content $agent -Raw
if ($agentText -notmatch '(?m)^using System\.IO;\s*$') {
    if ($agentText -notmatch '(?m)^using\s+') { throw 'Protection agent has no using directive anchor.' }
    $agentText = "using System.IO;`r`n" + $agentText
    Set-Content -Path $agent -Value $agentText -Encoding utf8
}

# Registry access is explicitly guarded at the narrow Windows-only call site so
# the application-only service boundary does not leak CA1416 to all host callers/tests.
$browserBootstrap = Join-Path $Root 'src/DKLock.Service/Protection/DefaultBrowserPolicyBootstrapper.cs'
if (-not (Test-Path $browserBootstrap)) { throw "Missing V10 default browser bootstrapper: $browserBootstrap" }
$browserText = Get-Content $browserBootstrap -Raw
$browserText = $browserText.Replace("[SupportedOSPlatform(`"windows`")]`r`ninternal sealed class DefaultBrowserPolicyBootstrapper", 'internal sealed class DefaultBrowserPolicyBootstrapper')
$browserText = $browserText.Replace("[SupportedOSPlatform(`"windows`")]`ninternal sealed class DefaultBrowserPolicyBootstrapper", 'internal sealed class DefaultBrowserPolicyBootstrapper')
$methodMarker = "    private string? ResolveOwnerLocalAppData()`r`n    {`r`n"
if (-not $browserText.Contains($methodMarker)) { $methodMarker = "    private string? ResolveOwnerLocalAppData()`n    {`n" }
if (-not $browserText.Contains('if (!OperatingSystem.IsWindows()) return null;')) {
    if (-not $browserText.Contains($methodMarker)) { throw 'ResolveOwnerLocalAppData marker not found for Windows guard.' }
    $browserText = $browserText.Replace($methodMarker, $methodMarker + "        if (!OperatingSystem.IsWindows()) return null;`r`n")
}
Set-Content -Path $browserBootstrap -Value $browserText -Encoding utf8

# Preserve the AlreadyAuthorized contract explicitly in the IPC Code as well as the
# typed response field. The desktop agent and runtime probe must never re-prompt or
# stall when the RAM-only UntilApplicationClose session is still valid.
$hostPath = Join-Path $Root 'src/DKLock.Service/DkLockServiceHost.cs'
if (-not (Test-Path $hostPath)) { throw "Missing V10 service host: $hostPath" }
$hostText = Get-Content $hostPath -Raw
$authorizedPattern = 'return IpcResponse\.Ok\(v, request\.RequestId, result\.AlreadyAuthorized \? "application already authorized" : "window challenge created",\s*_stateStore\.Current, challenge: result\.Challenge, alreadyAuthorized: result\.AlreadyAuthorized\);'
if ($hostText -notmatch 'windowResponse with \{ Code = "ALREADY_AUTHORIZED" \}') {
    if ($hostText -notmatch $authorizedPattern) { throw 'V10 window challenge response marker not found.' }
    $authorizedReplacement = @'
var windowResponse = IpcResponse.Ok(v, request.RequestId, result.AlreadyAuthorized ? "application already authorized" : "window challenge created",
            _stateStore.Current, challenge: result.Challenge, alreadyAuthorized: result.AlreadyAuthorized);
        return result.AlreadyAuthorized ? windowResponse with { Code = "ALREADY_AUTHORIZED" } : windowResponse;
'@
    $hostText = [regex]::Replace($hostText, $authorizedPattern, $authorizedReplacement, 1)
    Set-Content -Path $hostPath -Value $hostText -Encoding utf8
}

# Hydrate the production test/release assets and verify their immutable carrier hash.
$assetCarrier = Join-Path $PSScriptRoot 'v10-ci-assets.b64'
if (-not (Test-Path $assetCarrier)) { throw "Missing V10 test/release asset carrier: $assetCarrier" }
$assetArchive = Join-Path $tempRoot 'v10-ci-assets.tar.xz'
$assetB64 = (Get-Content $assetCarrier -Raw).Trim()
[IO.File]::WriteAllBytes($assetArchive, [Convert]::FromBase64String($assetB64))
$assetHash = (Get-FileHash $assetArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($assetHash -ne '72bfef81ed50ca736573b0222a8c5acfb26432f17bdc0110fea289302706370e') { throw "V10 test/release asset SHA mismatch: $assetHash" }
tar -xf $assetArchive -C $Root
if ($LASTEXITCODE -ne 0) { throw 'Failed to extract V10 test/release asset bundle.' }
Remove-Item $assetArchive -Force -ErrorAction SilentlyContinue
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

# Repair the recovered test asset deterministically and parser-validate it before execution.
$gateScript = Join-Path $Root 'scripts/test-v10.ps1'
$gateText = Get-Content $gateScript -Raw
$badReportLine = '"- Installer SHA-256: `$hash`", '''','
$goodReportLine = '("- Installer SHA-256: " + $hash), '''','
if ($gateText.Contains($badReportLine)) { $gateText = $gateText.Replace($badReportLine, $goodReportLine) }
$badHashLine = 'Write-Host "V10_USER_INSTALLER_SHA256=$((Get-FileHash $userZip -Algorithm SHA256).Hash.ToLowerInvariant())"'
$goodHashLines = '$userZipHash = (Get-FileHash $userZip -Algorithm SHA256).Hash.ToLowerInvariant()' + "`r`n" + 'Write-Host "V10_USER_INSTALLER_SHA256=$userZipHash"'
if ($gateText.Contains($badHashLine)) { $gateText = $gateText.Replace($badHashLine, $goodHashLines) }
Set-Content -Path $gateScript -Value $gateText -Encoding utf8

$parseTokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($gateScript, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -ne 0) {
    $messages = ($parseErrors | ForEach-Object Message) -join '; '
    throw "V10 production gate PowerShell parse failure after deterministic repair: $messages"
}

Write-Host "Applied exact V10 target override SHA256=$targetHash, narrow Windows registry guard, explicit ALREADY_AUTHORIZED IPC status, production asset SHA256=$assetHash, and parser-validated test-v10.ps1"
