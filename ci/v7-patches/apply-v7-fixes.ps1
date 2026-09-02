param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'

# Named-pipe ACL construction is Windows-only. Keep the ACL implementation intact and make the
# platform boundary explicit to the analyzer with a runtime guard instead of suppressing CA1416.
$pipeFactory = Join-Path $Root 'src/DKLock.Infrastructure/NamedPipeSecurityFactory.cs'
if (-not (Test-Path $pipeFactory)) { throw "Missing V7 pipe ACL source: $pipeFactory" }
$text = Get-Content $pipeFactory -Raw
if ($text -match '#pragma\s+warning\s+(disable|restore)\s+CA1416') {
    throw 'V7 pipe ACL source unexpectedly contains a CA1416 suppression.'
}
$pipeGuardMarker = '// V7: Named Pipe ACL construction is Windows-only.'
if ($text -notmatch [regex]::Escape($pipeGuardMarker)) {
    $methodPattern = '(?ms)(public\s+static\s+PipeSecurity\s+BuildSecurity\s*\([^)]*\)\s*\{)'
    if ($text -notmatch $methodPattern) { throw 'NamedPipeSecurityFactory.BuildSecurity method not found.' }
    $text = [regex]::Replace($text, $methodPattern, {
        param($match)
        $match.Groups[1].Value + "`r`n        $pipeGuardMarker`r`n        if (!OperatingSystem.IsWindows())`r`n            throw new System.PlatformNotSupportedException(`"DK LOCK Named Pipe ACL security is supported only on Windows.`");"
    }, 1)
    Set-Content $pipeFactory $text -Encoding utf8
}

# Setup sources explicitly use System.IO APIs.
foreach ($relative in @(
    'tools/DKLock.Setup/InstallerEngine.cs',
    'tools/DKLock.Setup/App.xaml.cs',
    'tools/DKLock.Setup/MainWindow.xaml.cs',
    'tools/DKLock.Setup/SetupOptions.cs',
    'tools/DKLock.Setup/SetupSmoke.cs')) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path $path)) { throw "Missing V7 setup source: $path" }
    $source = Get-Content $path -Raw
    if ($source -notmatch '(?m)^using System\.IO;\s*$') {
        Set-Content $path ("using System.IO;`r`n" + $source) -Encoding utf8
    }
}

# Production SCM mode must never inherit a test-only shutdown environment flag.
$servicePath = Join-Path $Root 'src/DKLock.Service/ServiceOptions.cs'
$service = Get-Content $servicePath -Raw
$serviceMarker = '// V7 production service safety: never expose the test-shutdown endpoint from SCM mode.'
if ($service -notmatch [regex]::Escape($serviceMarker)) {
    $guard = @"
        $serviceMarker
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
    if ($service -notmatch $returnPattern) { throw 'ServiceOptions return expression not found.' }
    $service = [regex]::Replace($service, $returnPattern, { param($m) $guard + $m.Groups[1].Value + 'return new ServiceOptions(' }, 1)
    Set-Content $servicePath $service -Encoding utf8
}

# Wait for an elevated child setup and propagate its actual exit code.
$appPath = Join-Path $Root 'tools/DKLock.Setup/App.xaml.cs'
$app = Get-Content $appPath -Raw
if ($app -notmatch 'var elevatedExitCode = SetupElevation\.RelaunchElevated') {
    $pattern = '(?m)^[ \t]*SetupElevation\.RelaunchElevated\(options, e\.Args\);\r?\n[ \t]*Shutdown\(0\);\r?\n[ \t]*return;'
    if ($app -notmatch $pattern) { throw 'Setup elevation startup block not found.' }
    $replacement = "                var elevatedExitCode = SetupElevation.RelaunchElevated(options, e.Args);`r`n                Shutdown(elevatedExitCode);`r`n                return;"
    $app = [regex]::Replace($app, $pattern, $replacement, 1)
}
$app = $app.Replace(
    'public static void RelaunchElevated(SetupOptions options, string[] originalArgs)',
    'public static int RelaunchElevated(SetupOptions options, string[] originalArgs)')
if ($app -notmatch 'return StartAndWait\(Environment\.ProcessPath!, args, elevate: true\);') {
    $pattern = '(?m)^[ \t]*Start\(Environment\.ProcessPath!, args, elevate: true\);'
    if ($app -notmatch $pattern) { throw 'Elevated setup launch line not found.' }
    $app = [regex]::Replace($app, $pattern, '        return StartAndWait(Environment.ProcessPath!, args, elevate: true);', 1)
}
if ($app -notmatch 'private static int StartAndWait\(') {
    $marker = '    private static void Start(string executable, IEnumerable<string> args, bool elevate)'
    if (-not $app.Contains($marker)) { throw 'Setup Start helper not found.' }
    $helper = @'
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
    $app = $app.Replace($marker, $helper + $marker)
}
Set-Content $appPath $app -Encoding utf8

# Keep PayloadIntegrity.VerifyDirectory unchanged and strict so unlisted files are rejected.
# DK_LOCK_V7_Setup.exe cannot self-hash inside its embedded manifest. Verify that EXE separately,
# temporarily move the installed copy outside the payload root, then run the original strict validator.
$installerPath = Join-Path $Root 'tools/DKLock.Setup/InstallerEngine.cs'
$installer = Get-Content $installerPath -Raw
$installer = $installer.Replace('PayloadIntegrity.VerifyDirectory(_options.InstallRoot);', 'VerifyInstalledDirectory(_options.InstallRoot);')
if ($installer -notmatch 'private static void VerifyInstalledDirectory\(') {
    $marker = '    private static string Quote(string value)'
    if (-not $installer.Contains($marker)) { throw 'Installer Quote helper not found.' }
    $helper = @'
    private static void VerifyInstalledDirectory(string root)
    {
        const string setupName = "DK_LOCK_V7_Setup.exe";
        var installedSetup = Path.Combine(root, setupName);
        var runningSetup = Environment.ProcessPath ?? throw new InvalidOperationException("Unable to resolve running setup executable for integrity verification.");
        if (!File.Exists(installedSetup)) throw new InvalidDataException("Installed setup executable is missing.");

        using (var source = File.OpenRead(runningSetup))
        using (var installed = File.OpenRead(installedSetup))
        {
            var sourceHash = SHA256.HashData(source);
            var installedHash = SHA256.HashData(installed);
            if (!CryptographicOperations.FixedTimeEquals(sourceHash, installedHash))
                throw new InvalidDataException("Installed setup executable integrity verification failed.");
        }

        var outsidePayload = Path.Combine(Path.GetTempPath(), $"dklock-v7-setup-verify-{Guid.NewGuid():N}.exe");
        File.Move(installedSetup, outsidePayload, overwrite: true);
        try
        {
            PayloadIntegrity.VerifyDirectory(root);
        }
        finally
        {
            if (File.Exists(outsidePayload)) File.Move(outsidePayload, installedSetup, overwrite: true);
        }
    }

'@
    $installer = $installer.Replace($marker, $helper + $marker)
}
$verifyCount = ([regex]::Matches($installer, 'VerifyInstalledDirectory\(_options\.InstallRoot\);')).Count
if ($verifyCount -lt 2) { throw "Expected two installed-directory checks; found $verifyCount." }
if ($installer -notmatch 'if \(!actualFiles\.SetEquals\(expectedFiles\)\)') { throw 'Strict unlisted-file payload check was unexpectedly changed.' }
if ($installer -match 'allowedExtraFiles|allowedExtras') { throw 'Payload validator was unexpectedly relaxed.' }
Set-Content $installerPath $installer -Encoding utf8

# PowerShell does not provide reliable wait/exit-code semantics for a Windows GUI executable when
# invoked with the native call operator. V7 install/repair/uninstall gates must wait for the exact
# Setup process to finish before examining Program Files, ProgramData, SCM, or registry state.
$testPath = Join-Path $Root 'scripts/test-v7.ps1'
if (-not (Test-Path $testPath)) { throw "Missing V7 release gate script: $testPath" }
$test = Get-Content $testPath -Raw
$setupProcessMarker = 'function Invoke-V7SetupProcess'
if ($test -notmatch [regex]::Escape($setupProcessMarker)) {
    $insertAfter = '(?m)^Set-Location \$root\r?\n'
    if ($test -notmatch $insertAfter) { throw 'V7 test Set-Location marker not found.' }
    $processHelper = @'

function Invoke-V7SetupProcess([string]$FilePath, [string[]]$Arguments) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $process) { throw "Unable to start V7 setup process: $FilePath" }
    try {
        $process.WaitForExit()
        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}
'@
    $test = [regex]::Replace($test, $insertAfter, { param($m) $m.Value + $processHelper + "`r`n" }, 1)
}

$replacements = [ordered]@{
    '& $setup --verify-only' = '$setupExit = Invoke-V7SetupProcess -FilePath $setup -Arguments @(''--verify-only'')'
    'if ($LASTEXITCODE -ne 0) { throw "Final setup embedded integrity verification failed." }' = 'if ($setupExit -ne 0) { throw "Final setup embedded integrity verification failed: $setupExit" }'
    '& $setup --silent @commonArgs' = '$setupExit = Invoke-V7SetupProcess -FilePath $setup -Arguments (@(''--silent'') + $commonArgs)'
    'if ($LASTEXITCODE -ne 0) { throw "V7 silent installation failed: $LASTEXITCODE" }' = 'if ($setupExit -ne 0) { throw "V7 silent installation failed: $setupExit" }'
    'if ($LASTEXITCODE -ne 0) { throw "V7 repair failed: $LASTEXITCODE" }' = 'if ($setupExit -ne 0) { throw "V7 repair failed: $setupExit" }'
    '& $setup --silent --uninstall @commonArgs' = '$setupExit = Invoke-V7SetupProcess -FilePath $setup -Arguments (@(''--silent'',''--uninstall'') + $commonArgs)'
    'if ($LASTEXITCODE -ne 0) { throw "V7 uninstall failed: $LASTEXITCODE" }' = 'if ($setupExit -ne 0) { throw "V7 uninstall failed: $setupExit" }'
    '& $setup --silent --uninstall --purge-data @commonArgs' = '$setupExit = Invoke-V7SetupProcess -FilePath $setup -Arguments (@(''--silent'',''--uninstall'',''--purge-data'') + $commonArgs)'
    'if ($LASTEXITCODE -ne 0) { throw "V7 purge cleanup failed: $LASTEXITCODE" }' = 'if ($setupExit -ne 0) { throw "V7 purge cleanup failed: $setupExit" }'
}
foreach ($pair in $replacements.GetEnumerator()) {
    if (-not $test.Contains($pair.Key)) { throw "Expected V7 setup gate invocation not found: $($pair.Key)" }
    $test = $test.Replace($pair.Key, $pair.Value)
}
if ($test -match '(?m)^\s*& \$setup\s') { throw 'A V7 setup gate still uses the non-waiting native call operator.' }
Set-Content $testPath $test -Encoding utf8

Write-Host 'Applied V7 production fixes: analyzer-safe Windows pipe ACL guard, setup imports, SCM shutdown safety, synchronous elevation, strict payload/setup integrity, deterministic Setup E2E waits.'
