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

# UI Automation Invoke is asynchronous with respect to the WPF dispatcher.
# The V9 release gate must still exercise the real Button -> ICommand ->
# IPC/Service path, but it must not inspect command state before the click has
# actually been dispatched. Apply the same ApplicationIdle synchronization to
# every real functional E2E click so Applications/Folders/Documents/Accounts/
# Settings/Quick Lock are tested consistently instead of patching one button at
# a time.
$methodToken = 'private static async Task<int> RunV9FunctionalUiE2EAsync'
$methodStart = $content.IndexOf($methodToken, [System.StringComparison]::Ordinal)
if ($methodStart -lt 0) { throw 'V9 functional UI E2E method was not found.' }
$helperToken = 'private static Button RequireButton'
$helperStart = $content.IndexOf($helperToken, $methodStart, [System.StringComparison]::Ordinal)
if ($helperStart -lt 0) { throw 'V9 functional UI E2E helper boundary was not found.' }

$prefix = $content.Substring(0, $methodStart)
$functional = $content.Substring($methodStart, $helperStart - $methodStart)
$suffix = $content.Substring($helperStart)
$sourceLines = [regex]::Split($functional, '\r?\n')
$rebuilt = New-Object System.Collections.Generic.List[string]
$invokeCount = 0
for ($i = 0; $i -lt $sourceLines.Count; $i++) {
    $line = $sourceLines[$i]

    # Remove an older per-button synchronization line if this patch already
    # added one immediately after an InvokeButton call; it will be recreated
    # uniformly below.
    if ($line -match '^\s*await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);\s*$' -and
        $rebuilt.Count -gt 0 -and $rebuilt[$rebuilt.Count - 1] -match '^\s*InvokeButton\(') {
        continue
    }

    $rebuilt.Add($line)
    if ($line -match '^(?<indent>\s*)InvokeButton\([^;]+\);\s*$') {
        $indent = $Matches['indent']
        $rebuilt.Add($indent + 'await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);')
        $invokeCount++
    }
}
if ($invokeCount -lt 6) { throw "Expected multiple V9 functional UI Automation clicks, synchronized only $invokeCount." }
$content = $prefix + ($rebuilt -join "`r`n") + $suffix

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
$syncCount = ([regex]::Matches($updated, 'await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);')).Count
if ($syncCount -lt $invokeCount) { throw "V9 functional UI dispatcher synchronization count mismatch: invokes=$invokeCount sync=$syncCount" }
if ($updated -notmatch 'DIAG_APPLICATION_AFTER_CLICK') { throw 'V9 Add Application failure diagnostic is missing.' }

Write-Host "Applied V9 integration fixes: onboarding namespace, modal scheduling capture, and dispatcher synchronization for all $invokeCount real functional UI Automation clicks."
