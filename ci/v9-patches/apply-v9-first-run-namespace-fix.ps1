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

# The modal onboarding smoke deliberately schedules an async UI driver before
# ShowDialog. Capture the DispatcherOperation explicitly so warnings-as-errors
# does not treat the scheduling call as an accidental unawaited operation.
$content = [regex]::Replace(
    $content,
    '(?m)^(?<indent>\s*)onboarding\.Dispatcher\.BeginInvoke\(',
    '${indent}_ = onboarding.Dispatcher.BeginInvoke('
)

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

Write-Host "Applied V9 FirstRunSetupWindow integration fixes: namespace=$namespace; modal driver scheduling captured."
