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

$appPath = Join-Path $Root 'tools/DKLock.Setup/App.xaml.cs'
$appText = Get-Content $appPath -Raw
$oldElevation = @"
                SetupElevation.RelaunchElevated(options, e.Args);
                Shutdown(0);
                return;
"@
$newElevation = @"
                var elevatedExitCode = SetupElevation.RelaunchElevated(options, e.Args);
                Shutdown(elevatedExitCode);
                return;
"@
if ($appText.Contains($oldElevation)) {
    $appText = $appText.Replace($oldElevation, $newElevation)
}
elseif ($appText -notmatch 'var elevatedExitCode = SetupElevation\.RelaunchElevated') {
    throw 'Could not patch V7 setup elevation exit-code propagation.'
}

$appText = $appText.Replace(
    'public static void RelaunchElevated(SetupOptions options, string[] originalArgs)',
    'public static int RelaunchElevated(SetupOptions options, string[] originalArgs)')

$oldElevatedStart = '        Start(Environment.ProcessPath!, args, elevate: true);'
$newElevatedStart = '        return StartAndWait(Environment.ProcessPath!, args, elevate: true);'
if ($appText.Contains($oldElevatedStart)) {
    $appText = $appText.Replace($oldElevatedStart, $newElevatedStart)
}
elseif ($appText -notmatch 'return StartAndWait\(Environment\.ProcessPath!, args, elevate: true\);') {
    throw 'Could not patch V7 elevated setup wait behavior.'
}

if ($appText -notmatch 'private static int StartAndWait\(') {
    $startMarker = '    private static void Start(string executable, IEnumerable<string> args, bool elevate)'
    if (-not $appText.Contains($startMarker)) {
        throw 'Could not locate V7 setup Start helper.'
    }
    $waitHelper = @"
    private static int StartAndWait(string executable, IEnumerable<string> args, bool elevate)
    {
        var psi = new ProcessStartInfo(executable)
        {
            UseShellExecute = true,
            Verb = elevate ? "runas" : string.Empty
        };
        foreach (var arg in args) psi.ArgumentList.Add(arg);
        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Unable to launch elevated DK LOCK setup process.");
        process.WaitForExit();
        return process.ExitCode;
    }

"@
    $appText = $appText.Replace($startMarker, $waitHelper + $startMarker)
}
Set-Content -Path $appPath -Value $appText -Encoding utf8

$installerPath = Join-Path $Root 'tools/DKLock.Setup/InstallerEngine.cs'
$installerText = Get-Content $installerPath -Raw
$installerText = $installerText.Replace('PayloadIntegrity.VerifyDirectory(_options.InstallRoot);', 'VerifyInstalledDirectory(_options.InstallRoot);')

if ($installerText -notmatch 'private static void VerifyInstalledDirectory\(') {
    $quoteMarker = '    private static string Quote(string value)'
    if (-not $installerText.Contains($quoteMarker)) {
        throw 'Could not locate V7 installer Quote helper.'
    }
    $installedVerify = @"
    private static void VerifyInstalledDirectory(string root)
    {
        // The installer is copied next to the payload after the payload manifest is built, so it cannot hash itself.
        // Keep payload verification strict while permitting exactly this one root-level setup file, then verify that
        // setup copy independently against the currently running release executable.
        const string setupName = "DK_LOCK_V7_Setup.exe";
        PayloadIntegrity.VerifyDirectory(root, setupName);

        var installedSetup = Path.Combine(root, setupName);
        var runningSetup = Environment.ProcessPath ?? throw new InvalidOperationException("Unable to resolve running setup executable for integrity verification.");
        if (!File.Exists(installedSetup)) throw new InvalidDataException("Installed setup executable is missing.");

        using var source = File.OpenRead(runningSetup);
        using var installed = File.OpenRead(installedSetup);
        var sourceHash = SHA256.HashData(source);
        var installedHash = SHA256.HashData(installed);
        if (!CryptographicOperations.FixedTimeEquals(sourceHash, installedHash))
            throw new InvalidDataException("Installed setup executable integrity verification failed.");
    }

"@
    $installerText = $installerText.Replace($quoteMarker, $installedVerify + $quoteMarker)
}

$oldSignature = '    public static void VerifyDirectory(string root)'
$newSignature = '    public static void VerifyDirectory(string root, params string[] allowedExtraFiles)'
if ($installerText.Contains($oldSignature)) {
    $installerText = $installerText.Replace($oldSignature, $newSignature)
}
elseif ($installerText -notmatch 'public static void VerifyDirectory\(string root, params string\[\] allowedExtraFiles\)') {
    throw 'Could not patch V7 payload verification signature.'
}

$oldSetCheck = @"
        var expectedFiles = expected.Keys.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!actualFiles.SetEquals(expectedFiles))
        {
            var unexpected = actualFiles.Except(expectedFiles).FirstOrDefault();
            var missing = expectedFiles.Except(actualFiles).FirstOrDefault();
            throw new InvalidDataException($"Payload file set mismatch. unexpected={unexpected ?? "none"}; missing={missing ?? "none"}");
        }
"@
$newSetCheck = @"
        var expectedFiles = expected.Keys.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var allowedExtras = allowedExtraFiles.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unexpected = actualFiles.Except(expectedFiles).Except(allowedExtras).FirstOrDefault();
        var missing = expectedFiles.Except(actualFiles).FirstOrDefault();
        if (unexpected is not null || missing is not null)
            throw new InvalidDataException($"Payload file set mismatch. unexpected={unexpected ?? "none"}; missing={missing ?? "none"}");
"@
if ($installerText.Contains($oldSetCheck)) {
    $installerText = $installerText.Replace($oldSetCheck, $newSetCheck)
}
elseif ($installerText -notmatch 'allowedExtras = allowedExtraFiles\.ToHashSet') {
    throw 'Could not patch V7 allowed setup-file integrity logic.'
}

if (($installerText | Select-String -Pattern 'VerifyInstalledDirectory\(_options\.InstallRoot\);' -AllMatches).Matches.Count -lt 2) {
    throw 'Expected both V7 installed-directory integrity checks to use VerifyInstalledDirectory.'
}
Set-Content -Path $installerPath -Value $installerText -Encoding utf8

Write-Host 'Applied V7 Windows-only named-pipe ACL analyzer annotation patch.'
Write-Host 'Applied V7 explicit System.IO imports for setup sources.'
Write-Host 'Applied V7 production service test-shutdown safety patch.'
Write-Host 'Applied V7 synchronous elevation/exit-code propagation patch.'
Write-Host 'Applied V7 installed setup executable integrity patch.'
