param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'

$pipeFactory = Join-Path $Root 'src/DKLock.Infrastructure/NamedPipeSecurityFactory.cs'
if (-not (Test-Path $pipeFactory)) {
    throw "V7 patch target not found: $pipeFactory"
}

$content = Get-Content $pipeFactory -Raw
if ($content -notmatch '#pragma warning disable CA1416') {
    $reason = '// V7: this factory is intentionally Windows-only because production named-pipe ACLs use Windows access-control APIs.'
    $content = "#pragma warning disable CA1416`r`n$reason`r`n" + $content.TrimEnd() + "`r`n#pragma warning restore CA1416`r`n"
    Set-Content -Path $pipeFactory -Value $content -Encoding utf8
}

$setupFiles = @(
    'tools/DKLock.Setup/InstallerEngine.cs',
    'tools/DKLock.Setup/App.xaml.cs',
    'tools/DKLock.Setup/MainWindow.xaml.cs',
    'tools/DKLock.Setup/SetupOptions.cs',
    'tools/DKLock.Setup/SetupSmoke.cs'
)

foreach ($relative in $setupFiles) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path $path)) {
        throw "V7 setup patch target not found: $path"
    }

    $text = Get-Content $path -Raw
    if ($text -notmatch '(?m)^using System\.IO;\s*$') {
        $text = "using System.IO;`r`n" + $text
        Set-Content -Path $path -Value $text -Encoding utf8
    }
}

$serviceOptions = Join-Path $Root 'src/DKLock.Service/ServiceOptions.cs'
if (-not (Test-Path $serviceOptions)) {
    throw "V7 service-options patch target not found: $serviceOptions"
}

$serviceText = Get-Content $serviceOptions -Raw
$marker = '// V7 production service safety: never expose the test-shutdown endpoint from SCM mode.'
if ($serviceText -notmatch [regex]::Escape($marker)) {
    $guard = @"
        $marker
        foreach (var arg in args)
        {
            if (string.Equals(arg, "--windows-service", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(arg, "--service", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(arg, "--scm", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(arg, "--run-as-service", StringComparison.OrdinalIgnoreCase))
            {
                allowTestShutdown = false;
                break;
            }
        }

"@
    $pattern = '(?m)^(\s*)return new ServiceOptions\('
    if ($serviceText -notmatch $pattern) {
        throw 'Could not locate ServiceOptions return expression for production shutdown safety patch.'
    }
    $serviceText = [regex]::Replace($serviceText, $pattern, { param($m) $guard + $m.Groups[1].Value + 'return new ServiceOptions(' }, 1)
    Set-Content -Path $serviceOptions -Value $serviceText -Encoding utf8
}

Write-Host 'Applied V7 Windows-only named-pipe ACL analyzer annotation patch.'
Write-Host 'Applied V7 explicit System.IO imports for setup sources.'
Write-Host 'Applied V7 production service test-shutdown safety patch.'
