param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = 'Stop'
$appRoot = Join-Path $Root 'src/DKLock.App'
$smokePath = Join-Path $appRoot 'Smoke/SmokeTestRunner.cs'
if (-not (Test-Path $smokePath)) { throw "V9 SmokeTestRunner not found: $smokePath" }

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

$content = [regex]::Replace(
    $content,
    '(?m)^(?<indent>\s*)onboarding\.Dispatcher\.BeginInvoke\(',
    '${indent}_ = onboarding.Dispatcher.BeginInvoke('
)

# Ensure the real UI Automation click has been dispatched before testing the
# resulting asynchronous command state. This keeps the path Button -> ICommand
# -> IPC/Service intact and removes only the E2E driver's event-queue race.
if ($content -notmatch 'InvokeButton\(refreshApplications\);\s*await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);') {
    $content = [regex]::Replace(
        $content,
        '(?m)^(?<indent>\s*)InvokeButton\(refreshApplications\);\s*$',
        '${indent}InvokeButton(refreshApplications);' + "`r`n" + '${indent}await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);',
        1
    )
}
if ($content -notmatch 'InvokeButton\(addApplication\);\s*await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);') {
    $content = [regex]::Replace(
        $content,
        '(?m)^(?<indent>\s*)InvokeButton\(addApplication\);\s*$',
        '${indent}InvokeButton(addApplication);' + "`r`n" + '${indent}await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);',
        1
    )
}

if ($content -notmatch 'DIAG_APPLICATION_AFTER_CLICK') {
    $assertPattern = '(?m)^(?<indent>\s*)Require\(await WaitUntilAsync\(\(\) => applications\.Applications\.Count == 1, TimeSpan\.FromSeconds\(8\)\), "Add application UI command persists a protection policy", lines\);\s*$'
    $assertMatch = [regex]::Match($content, $assertPattern)
    if (-not $assertMatch.Success) { throw 'V9 Add Application assertion line was not found.' }
    $indent = $assertMatch.Groups['indent'].Value
    $replacement = $indent + 'var applicationAdded = await WaitUntilAsync(() => applications.Applications.Count == 1, TimeSpan.FromSeconds(8));' + "`r`n" +
        $indent + 'if (!applicationAdded)' + "`r`n" +
        $indent + '{' + "`r`n" +
        $indent + '    lines.Add($"DIAG_APPLICATION_AFTER_CLICK: Busy={applications.Busy}; VmCount={applications.Applications.Count}; Status={applications.StatusMessage}");' + "`r`n" +
        $indent + '}' + "`r`n" +
        $indent + 'Require(applicationAdded, "Add application UI command persists a protection policy", lines);'
    $content = [regex]::Replace($content, $assertPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement }, 1)
}

Set-Content -Path $smokePath -Value $content -Encoding utf8
$updated = Get-Content $smokePath -Raw
if ($updated -notmatch [regex]::Escape($usingLine)) { throw 'Failed to import FirstRunSetupWindow namespace.' }
if ($updated -match '(?m)^\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Uncaptured onboarding Dispatcher.BeginInvoke remains.' }
if ($updated -notmatch '(?m)^\s*_\s*=\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Onboarding Dispatcher.BeginInvoke scheduling fix was not applied.' }
if ($updated -notmatch 'InvokeButton\(refreshApplications\);\s*await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);') { throw 'Refresh UI Automation dispatcher synchronization was not applied.' }
if ($updated -notmatch 'InvokeButton\(addApplication\);\s*await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);') { throw 'Add UI Automation dispatcher synchronization was not applied.' }
if ($updated -notmatch 'DIAG_APPLICATION_AFTER_CLICK') { throw 'V9 Add Application failure diagnostic is missing.' }

Write-Host 'Applied V9 integration fixes: onboarding namespace, modal scheduling capture, and real UI Automation dispatcher synchronization for Application Refresh/Add.'
