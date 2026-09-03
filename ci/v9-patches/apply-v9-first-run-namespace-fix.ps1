param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = 'Stop'

$appRoot = Join-Path $Root 'src/DKLock.App'
$smokePath = Join-Path $appRoot 'Smoke/SmokeTestRunner.cs'
$testV9Path = Join-Path $Root 'scripts/test-v9.ps1'

if (-not (Test-Path $smokePath)) { throw "V9 SmokeTestRunner not found: $smokePath" }
if (-not (Test-Path $testV9Path)) { throw "V9 release gate script not found: $testV9Path" }

$firstRunXaml = Get-ChildItem -Path $appRoot -Recurse -File -Filter 'FirstRunSetupWindow.xaml' | Select-Object -First 1
if ($null -eq $firstRunXaml) { throw 'V9 FirstRunSetupWindow.xaml was not found in DKLock.App.' }
$xaml = Get-Content $firstRunXaml.FullName -Raw
$match = [regex]::Match($xaml, 'x:Class\s*=\s*"(?<class>[^"]+\.FirstRunSetupWindow)"')
if (-not $match.Success) { throw "Unable to resolve FirstRunSetupWindow x:Class from $($firstRunXaml.FullName)." }
$fullClass = $match.Groups['class'].Value
$namespace = $fullClass.Substring(0, $fullClass.LastIndexOf('.'))
$usingLine = "using $namespace;"

$content = Get-Content $smokePath -Raw
if ($content -notmatch [regex]::Escape($usingLine)) {
    $firstNamespace = [regex]::Match($content, '(?m)^namespace\s+')
    if (-not $firstNamespace.Success) { throw 'SmokeTestRunner namespace declaration was not found.' }
    $insertAt = $firstNamespace.Index
    $content = $content.Substring(0, $insertAt).TrimEnd() + "`r`n$usingLine`r`n`r`n" + $content.Substring($insertAt)
}
$content = [regex]::Replace($content, '(?m)^(?<indent>\s*)onboarding\.Dispatcher\.BeginInvoke\(', '${indent}_ = onboarding.Dispatcher.BeginInvoke(')

$oldApplicationAssertion = '            Require(await WaitUntilAsync(() => applications.Applications.Count == 1, TimeSpan.FromSeconds(8)), "Add application UI command persists a protection policy", lines);'
if ($content.Contains($oldApplicationAssertion)) {
    $newApplicationAssertion = @'
            var applicationAdded = await WaitUntilAsync(() => applications.Applications.Count == 1, TimeSpan.FromSeconds(8));
            if (!applicationAdded)
            {
                lines.Add($"DIAG_APPLICATION_AFTER_CLICK: Busy={applications.Busy}; VmCount={applications.Applications.Count}; Status={applications.StatusMessage}");
            }
            Require(applicationAdded, "Add application UI command persists a protection policy", lines);
'@
    $content = $content.Replace($oldApplicationAssertion, $newApplicationAssertion.TrimEnd())
}
Set-Content -Path $smokePath -Value $content -Encoding utf8

$updated = Get-Content $smokePath -Raw
if ($updated -notmatch [regex]::Escape($usingLine)) { throw "Failed to import FirstRunSetupWindow namespace: $namespace" }
if ($updated -match '(?m)^\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Uncaptured onboarding Dispatcher.BeginInvoke remains.' }
if ($updated -notmatch '(?m)^\s*_\s*=\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Onboarding Dispatcher.BeginInvoke scheduling fix was not applied.' }
if ($updated -notmatch 'DIAG_APPLICATION_AFTER_CLICK') { throw 'V9 Add Application failure diagnostic was not injected.' }

$gateLines = Get-Content $testV9Path
$patterns = @('--v9-functional-ui-e2e', 'DKLOCK_V9_E2E_APP', '\[12/22\]')
$printed = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($pattern in $patterns) {
    $hits = Select-String -Path $testV9Path -Pattern $pattern
    foreach ($hit in $hits) {
        $start = [Math]::Max(0, $hit.LineNumber - 25)
        $end = [Math]::Min($gateLines.Count - 1, $hit.LineNumber + 35)
        Write-Host "--- test-v9.ps1 context for $pattern at line $($hit.LineNumber) ---"
        for ($i = $start; $i -le $end; $i++) {
            if ($printed.Add($i)) { Write-Host ('{0,4}: {1}' -f ($i + 1), $gateLines[$i]) }
        }
    }
}

Write-Host 'V9 Gate 12 environment/launch diagnostic captured; stopping before expensive release gates.'
throw 'V9_DIAGNOSTIC_STOP_AFTER_GATE12_LAUNCH_INSPECTION'
