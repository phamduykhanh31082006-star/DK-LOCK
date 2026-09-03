param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = 'Stop'
$appRoot = Join-Path $Root 'src/DKLock.App'
$smokePath = Join-Path $appRoot 'Smoke/SmokeTestRunner.cs'
if (-not (Test-Path $smokePath)) { throw "V9 SmokeTestRunner not found: $smokePath" }

# First-run onboarding class lives in the Dialogs namespace; resolve the namespace
# from XAML so the integration patch remains tied to the actual generated class.
$firstRunXaml = Get-ChildItem -Path $appRoot -Recurse -File -Filter 'FirstRunSetupWindow.xaml' | Select-Object -First 1
if ($null -eq $firstRunXaml) { throw 'V9 FirstRunSetupWindow.xaml missing.' }
$xaml = Get-Content $firstRunXaml.FullName -Raw
$m = [regex]::Match($xaml, 'x:Class\s*=\s*"(?<class>[^"]+\.FirstRunSetupWindow)"')
if (-not $m.Success) { throw 'Unable to resolve FirstRunSetupWindow x:Class.' }
$fullClass = $m.Groups['class'].Value
$usingLine = 'using ' + $fullClass.Substring(0, $fullClass.LastIndexOf('.')) + ';'
$content = Get-Content $smokePath -Raw
if ($content -notmatch [regex]::Escape($usingLine)) {
    $n = [regex]::Match($content, '(?m)^namespace\s+')
    if (-not $n.Success) { throw 'Smoke namespace missing.' }
    $content = $content.Substring(0,$n.Index).TrimEnd() + "`r`n$usingLine`r`n`r`n" + $content.Substring($n.Index)
}

# Modal onboarding deliberately schedules its async driver before ShowDialog.
# Capture the DispatcherOperation so warnings-as-errors does not flag CS4014.
$content = [regex]::Replace(
    $content,
    '(?m)^(?<indent>\s*)onboarding\.Dispatcher\.BeginInvoke\(',
    '${indent}_ = onboarding.Dispatcher.BeginInvoke('
)

# WPF UI Automation Invoke is dispatcher-scheduled. Pump through ApplicationIdle
# after the real Refresh and Add button invokes so the next assertion cannot race
# ahead of the command event. The product commands are still reached via buttons.
$refreshInvoke = @'
            InvokeButton(refreshApplications);
            Require(await WaitUntilAsync(() => !applications.Busy && refreshApplications.IsEnabled && addApplication.IsEnabled, TimeSpan.FromSeconds(6)), "Application Refresh and Add buttons re-enable after the real Refresh command completes", lines);
'@
$refreshInvokeFixed = @'
            InvokeButton(refreshApplications);
            await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            Require(await WaitUntilAsync(() => !applications.Busy && refreshApplications.IsEnabled && addApplication.IsEnabled, TimeSpan.FromSeconds(6)), "Application Refresh and Add buttons re-enable after the real Refresh command completes", lines);
'@
if ($content.Contains($refreshInvoke.Trim())) {
    $content = $content.Replace($refreshInvoke.Trim(), $refreshInvokeFixed.Trim())
}

$addInvoke = @'
            InvokeButton(addApplication);
            Require(await WaitUntilAsync(() => applications.Applications.Count == 1, TimeSpan.FromSeconds(8)), "Add application UI command persists a protection policy", lines);
'@
$addInvokeFixed = @'
            InvokeButton(addApplication);
            await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            var applicationAdded = await WaitUntilAsync(() => applications.Applications.Count == 1, TimeSpan.FromSeconds(8));
            if (!applicationAdded)
            {
                lines.Add($"DIAG_APPLICATION_AFTER_CLICK: Busy={applications.Busy}; VmCount={applications.Applications.Count}; Status={applications.StatusMessage}");
            }
            Require(applicationAdded, "Add application UI command persists a protection policy", lines);
'@
if ($content.Contains($addInvoke.Trim())) {
    $content = $content.Replace($addInvoke.Trim(), $addInvokeFixed.Trim())
} elseif ($content -notmatch 'DIAG_APPLICATION_AFTER_CLICK') {
    throw 'V9 Add Application assertion block was not found.'
}

Set-Content -Path $smokePath -Value $content -Encoding utf8
$updated = Get-Content $smokePath -Raw
if ($updated -notmatch [regex]::Escape($usingLine)) { throw "Failed to import FirstRunSetupWindow namespace." }
if ($updated -match '(?m)^\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Uncaptured onboarding Dispatcher.BeginInvoke remains.' }
if ($updated -notmatch '(?m)^\s*_\s*=\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Onboarding Dispatcher.BeginInvoke scheduling fix was not applied.' }
if ($updated -notmatch 'InvokeButton\(refreshApplications\);\s*await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);') { throw 'Refresh UI Automation dispatcher synchronization was not applied.' }
if ($updated -notmatch 'InvokeButton\(addApplication\);\s*await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);') { throw 'Add UI Automation dispatcher synchronization was not applied.' }
if ($updated -notmatch 'DIAG_APPLICATION_AFTER_CLICK') { throw 'V9 Add Application failure diagnostic is missing.' }

Write-Host 'Applied V9 integration fixes: onboarding namespace, modal scheduling capture, and real UI Automation dispatcher synchronization for Application Refresh/Add.'
