param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'

# 1) V7 production named-pipe ACL APIs are intentionally Windows-only.
$pipeFactory = Join-Path $Root 'src/DKLock.Infrastructure/NamedPipeSecurityFactory.cs'
if (-not (Test-Path $pipeFactory)) { throw "V7 patch target not found: $pipeFactory" }
$content = Get-Content $pipeFactory -Raw
if ($content -notmatch '#pragma warning disable CA1416') {
    $reason = '// V7: this factory is intentionally Windows-only because production named-pipe ACLs use Windows access-control APIs.'
    $content = "#pragma warning disable CA1416`r`n$reason`r`n" + $content.TrimEnd() + "`r`n#pragma warning restore CA1416`r`n"
    Set-Content -Path $pipeFactory -Value $content -Encoding utf8
}

# 2) V7 setup files use Path/File/Directory APIs explicitly.
$setupFiles = @(
    'tools/DKLock.Setup/InstallerEngine.cs',
    'tools/DKLock.Setup/App.xaml.cs',
    'tools/DKLock.Setup/MainWindow.xaml.cs',
    'tools/DKLock.Setup/SetupOptions.cs',
    'tools/DKLock.Setup/SetupSmoke.cs'
)
foreach ($relative in $setupFiles) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path $path)) { throw "V7 setup patch target not found: $path" }
    $text = Get-Content $path -Raw
    if ($text -notmatch '(?m)^using System\.IO;\s*$') {
        $text = "using System.IO;`r`n" + $text
        Set-Content -Path $path -Value $text -Encoding utf8
    }
}

# 3) SCM/production mode must always override any test-only shutdown environment flag.
$serviceOptions = Join-Path $Root 'src/DKLock.Service/ServiceOptions.cs'
if (-not (Test-Path $serviceOptions)) { throw "V7 service-options patch target not found: $serviceOptions" }
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
    $returnPattern = '(?m)^(\s*)return new ServiceOptions\('
    if ($serviceText -notmatch $returnPattern) { throw 'Could not locate ServiceOptions return expression.' }
    $serviceText = [regex]::Replace($serviceText, $returnPattern, { param($m) $guard + $m.Groups[1].Value + 'return new ServiceOptions(' }, 1)
    Set-Content -Path $serviceOptions -Value $serviceText -Encoding utf8
}

# 4) An unelevated setup parent must wait for the elevated child and propagate its exit code.
# Otherwise silent automation/user scripts can observe exit 0 while installation is still running.
$appPath = Join-Path $Root 'tools/DKLock.Setup/App.xaml.cs'
$appText = Get-Content $appPath -Raw
if ($appText -notmatch 'var elevatedExitCode = SetupElevation\.RelaunchElevated') {
    $elevationPattern = '(?m)^[ \t]*SetupElevation\.RelaunchElevated\(options, e\.Args\);\r?\n[ \t]*Shutdown\(0\);\r?\n[ \t]*return;'
    if ($appText -notmatch $elevationPattern) { throw 'Could not locate V7 setup elevation startup block.' }
    $elevationReplacement = "                var elevatedExitCode = SetupElevation.RelaunchElevated(options, e.Args);`r`n                Shutdown(elevatedExitCode);`r`n                return;"
    $appText = [regex]::Replace($appText, $elevationPattern, $elevationReplacement, 1)
}

if ($appText -match 'public static void RelaunchElevated\(SetupOptions options, string\[\] originalArgs\)') {
    $appText = [regex]::Replace(
        $appText,
        'public static void RelaunchElevated\(SetupOptions options, string\[\] originalArgs\)',
        'public static int RelaunchElevated(SetupOptions options, string[] originalArgs)',
        1)
}
elseif ($appText -notmatch 'public static int RelaunchElevated\(SetupOptions options, string\[\] originalArgs\)') {
    throw 'Could not locate V7 RelaunchElevated signature.'
}

if ($appText -notmatch 'return StartAndWait\(Environment\.ProcessPath!, args, elevate: true\);') {
    $elevatedStartPattern = '(?m)^[ \t]*Start\(Environment\.ProcessPath!, args, elevate: true\);'
    if ($appText -notmatch $elevatedStartPattern) { throw 'Could not locate V7 elevated child launch.' }
    $appText = [regex]::Replace($appText, $elevatedStartPattern, '        return StartAndWait(Environment.ProcessPath!, args, elevate: true);', 1)
}

if ($appText -notmatch 'private static int StartAndWait\(') {
    $startMarker = '    private static void Start(string executable, IEnumerable<string> args, bool elevate)'
    if (-not $appText.Contains($startMarker)) { throw 'Could not locate V7 setup Start helper.' }
    $waitHelper = @'
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

'@
    $appText = $appText.Replace($startMarker, $waitHelper + $startMarker)
}
Set-Content -Path $appPath -Value $appText -Encoding utf8

# 5) The embedded payload manifest cannot contain a hash of the setup EXE that embeds that manifest.
# Keep payload file-set verification strict, permit exactly the root setup EXE only for installed-directory
# verification, and hash-compare that copy against the currently executing setup binary.
$installerPath = Join-Path $Root 'tools/DKLock.Setup/InstallerEngine.cs'
$installerText = Get-Content $installerPath -Raw
$installerText = $installerText.Replace('PayloadIntegrity.VerifyDirectory(_options.InstallRoot);', 'VerifyInstalledDirectory(_options.InstallRoot);')

if ($installerText -notmatch 'private static void VerifyInstalledDirectory\(') {
    $quoteMarker = '    private static string Quote(string value)'
    if (-not $installerText.Contains($quoteMarker)) { throw 'Could not locate V7 installer Quote helper.' }
    $installedVerify = @'
    private static void VerifyInstalledDirectory(string root)
    {
        // The setup executable embeds the payload manifest, so its own hash cannot be part of that manifest.
        // Permit only this root-level file as an extra, then verify the copied setup independently.
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

'@
    $installerText = $installerText.Replace($quoteMarker, $installedVerify + $quoteMarker)
}

if ($installerText -match 'public static void VerifyDirectory\(string root\)') {
    $installerText = [regex]::Replace(
        $installerText,
        'public static void VerifyDirectory\(string root\)',
        'public static void VerifyDirectory(string root, params string[] allowedExtraFiles)',
        1)
}
elseif ($installerText -notmatch 'public static void VerifyDirectory\(string root, params string\[\] allowedExtraFiles\)') {
    throw 'Could not locate V7 payload VerifyDirectory signature.'
}

if ($installerText -notmatch 'allowedExtras = allowedExtraFiles\.ToHashSet') {
    $expectedLine = '        var expectedFiles = expected.Keys.ToHashSet(StringComparer.OrdinalIgnoreCase);'
    if (-not $installerText.Contains($expectedLine)) { throw 'Could not locate V7 expectedFiles line.' }
    $newExpectedLines = $expectedLine + "`r`n        var allowedExtras = allowedExtraFiles.ToHashSet(StringComparer.OrdinalIgnoreCase);"
    $installerText = $installerText.Replace($expectedLine, $newExpectedLines)

    $setEqualsLine = '        if (!actualFiles.SetEquals(expectedFiles))'
    if (-not $installerText.Contains($setEqualsLine)) { throw 'Could not locate V7 payload file-set check.' }
    $newCondition = "        var unexpected = actualFiles.Except(expectedFiles).Except(allowedExtras).FirstOrDefault();`r`n        var missing = expectedFiles.Except(actualFiles).FirstOrDefault();`r`n        if (unexpected is not null || missing is not null)"
    $installerText = $installerText.Replace($setEqualsLine, $newCondition)

    # Remove the now-duplicated declarations that were inside the original mismatch block.
    $installerText = [regex]::Replace($installerText, '(?m)^[ \t]+var unexpected = actualFiles\.Except\(expectedFiles\)\.FirstOrDefault\(\);\r?\n', '', 1)
    $installerText = [regex]::Replace($installerText, '(?m)^[ \t]+var missing = expectedFiles\.Except\(actualFiles\)\.FirstOrDefault\(\);\r?\n', '', 1)
}

$verifyCount = ([regex]::Matches($installerText, 'VerifyInstalledDirectory\(_options\.InstallRoot\);')).Count
if ($verifyCount -lt 2) { throw "Expected both installed-directory checks to be patched; found $verifyCount." }
Set-Content -Path $installerPath -Value $installerText -Encoding utf8

Write-Host 'Applied V7 Windows-only named-pipe ACL analyzer annotation patch.'
Write-Host 'Applied V7 explicit System.IO imports for setup sources.'
Write-Host 'Applied V7 production service test-shutdown safety patch.'
Write-Host 'Applied V7 synchronous elevation/exit-code propagation patch.'
Write-Host 'Applied V7 installed setup executable integrity patch.'
