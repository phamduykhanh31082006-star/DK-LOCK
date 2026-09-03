param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = 'Stop'

$appRoot = Join-Path $Root 'src/DKLock.App'
$smokePath = Join-Path $appRoot 'Smoke/SmokeTestRunner.cs'

if (-not (Test-Path $smokePath)) {
    throw "V9 SmokeTestRunner not found: $smokePath"
}

$firstRunXaml = Get-ChildItem -Path $appRoot -Recurse -File -Filter 'FirstRunSetupWindow.xaml' | Select-Object -First 1
if ($null -eq $firstRunXaml) {
    throw 'V9 FirstRunSetupWindow.xaml was not found in DKLock.App.'
}

$xaml = Get-Content $firstRunXaml.FullName -Raw
$match = [regex]::Match($xaml, 'x:Class\s*=\s*"(?<class>[^"]+\.FirstRunSetupWindow)"')
if (-not $match.Success) {
    throw "Unable to resolve FirstRunSetupWindow x:Class from $($firstRunXaml.FullName)."
}

$fullClass = $match.Groups['class'].Value
$namespace = $fullClass.Substring(0, $fullClass.LastIndexOf('.'))
$usingLine = "using $namespace;"

$content = Get-Content $smokePath -Raw
if ($content -notmatch [regex]::Escape($usingLine)) {
    $firstNamespace = [regex]::Match($content, '(?m)^namespace\s+')
    if (-not $firstNamespace.Success) {
        throw 'SmokeTestRunner namespace declaration was not found.'
    }

    $insertAt = $firstNamespace.Index
    $prefix = $content.Substring(0, $insertAt)
    $suffix = $content.Substring($insertAt)
    $content = $prefix.TrimEnd() + "`r`n$usingLine`r`n`r`n" + $suffix
}

$content = [regex]::Replace(
    $content,
    '(?m)^(?<indent>\s*)onboarding\.Dispatcher\.BeginInvoke\(',
    '${indent}_ = onboarding.Dispatcher.BeginInvoke('
)

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
if ($updated -notmatch [regex]::Escape($usingLine)) {
    throw "Failed to import FirstRunSetupWindow namespace: $namespace"
}
if ($updated -match '(?m)^\s*onboarding\.Dispatcher\.BeginInvoke\(') {
    throw 'Uncaptured onboarding Dispatcher.BeginInvoke remains.'
}
if ($updated -notmatch '(?m)^\s*_\s*=\s*onboarding\.Dispatcher\.BeginInvoke\(') {
    throw 'Onboarding Dispatcher.BeginInvoke scheduling fix was not applied.'
}
if ($updated -notmatch 'DIAG_APPLICATION_AFTER_CLICK') {
    throw 'V9 Add Application failure diagnostic was not injected.'
}

$lines = Get-Content $smokePath
$hit = Select-String -Path $smokePath -SimpleMatch 'DIAG_APPLICATION_AFTER_CLICK' | Select-Object -First 1
if ($null -ne $hit) {
    Write-Host '--- V9 functional smoke context diagnostic ---'
    $start = [Math]::Max(0, $hit.LineNumber - 38)
    $end = [Math]::Min($lines.Count - 1, $hit.LineNumber + 8)
    for ($i = $start; $i -le $end; $i++) {
        Write-Host ('{0,4}: {1}' -f ($i + 1), $lines[$i])
    }
    Write-Host '--- end V9 functional smoke context diagnostic ---'
}

Write-Host "Applied V9 integration fixes: namespace=$namespace; modal driver scheduling captured; Add Application diagnostics compile-safe."
