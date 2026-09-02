param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'

$installerPath = Join-Path $Root 'tools/DKLock.Setup/InstallerEngine.cs'
if (-not (Test-Path $installerPath)) { throw "Missing V7 installer source: $installerPath" }
$installer = Get-Content $installerPath -Raw

# Repair originally renamed the entire install root to a sibling under Program Files. Windows can
# deny that parent-directory rename even when the installer can update files inside the product
# directory. Preserve the same transactional guarantee by snapshotting verified installed binaries
# into a private temp rollback directory, then clearing/repopulating the existing install root.
$oldBackupPattern = '(?ms)            if \(Directory\.Exists\(_options\.InstallRoot\)\)\r?\n            \{\r?\n                rollback = _options\.InstallRoot\.TrimEnd\(Path\.DirectorySeparatorChar\) \+ \$"\.rollback-\{Guid\.NewGuid\(\):N\}";\r?\n                Directory\.Move\(_options\.InstallRoot, rollback\);\r?\n            \}'
if ($installer -notmatch $oldBackupPattern) {
    throw 'Expected V7 Program Files root-rename rollback block was not found.'
}
$newBackupBlock = @'
            if (Directory.Exists(_options.InstallRoot))
            {
                Report(22, "Snapshotting installed binaries for transactional repair...");
                rollback = Path.Combine(Path.GetTempPath(), $"dklock-v7-rollback-{Guid.NewGuid():N}");
                CopyDirectory(_options.InstallRoot, rollback);
                ClearDirectory(_options.InstallRoot);
            }
'@
$installer = [regex]::Replace($installer, $oldBackupPattern, $newBackupBlock.TrimEnd(), 1)

$oldRestorePattern = '(?ms)^[ \t]*TryDeleteDirectory\(_options\.InstallRoot\);\r?\n[ \t]*if \(rollback is not null && Directory\.Exists\(rollback\)\) Directory\.Move\(rollback, _options\.InstallRoot\);'
if ($installer -notmatch $oldRestorePattern) {
    throw 'Expected V7 rollback restore block was not found.'
}
$newRestore = @'
                if (rollback is not null && Directory.Exists(rollback))
                {
                    ClearDirectory(_options.InstallRoot);
                    CopyDirectory(rollback, _options.InstallRoot);
                }
                else
                {
                    TryDeleteDirectory(_options.InstallRoot);
                }
'@
$installer = [regex]::Replace($installer, $oldRestorePattern, $newRestore.TrimEnd(), 1)

if ($installer -notmatch 'private static void ClearDirectory\(') {
    $marker = '    private static void TryDeleteDirectory(string path)'
    if (-not $installer.Contains($marker)) { throw 'Installer TryDeleteDirectory helper not found.' }
    $helper = @'
    private static void ClearDirectory(string path)
    {
        if (!Directory.Exists(path)) return;

        foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories).ToList())
        {
            File.SetAttributes(file, FileAttributes.Normal);
            File.Delete(file);
        }

        foreach (var directory in Directory.EnumerateDirectories(path, "*", SearchOption.AllDirectories)
                     .OrderByDescending(value => value.Length)
                     .ToList())
        {
            Directory.Delete(directory, recursive: false);
        }
    }

'@
    $installer = $installer.Replace($marker, $helper + $marker)
}

# Preserve exact SCM diagnostics and recent .NET/Application crash events when a repaired service
# starts but never reaches RUNNING. This is emitted only through the CI evidence hook already
# guarded by DKLOCK_V7_EVIDENCE_DIR; normal production behavior and release gates are unchanged.
$startPattern = '(?ms)    private async Task StartServiceAsync\(bool ignoreFailure = false\).*?(?=\r?\n    private async Task StopServiceAsync\(\))'
$startMatch = [regex]::Match($installer, $startPattern)
if (-not $startMatch.Success) { throw 'V7 StartServiceAsync method not found.' }
$startMethod = $startMatch.Value
if ($startMethod -notmatch 'ProcessResult\? lastQuery') {
    $loopLine = '        for (var i = 0; i < 40; i++)'
    if (-not $startMethod.Contains($loopLine)) { throw 'V7 service start poll loop not found.' }
    $startMethod = $startMethod.Replace($loopLine, "        ProcessResult? lastQuery = null;`r`n        for (var i = 0; i < 40; i++)")

    $queryLine = '            var query = await ProcessRunner.RunAsync("sc.exe", "query", _options.ServiceName);'
    if (-not $startMethod.Contains($queryLine)) { throw 'V7 service start query line not found.' }
    $startMethod = $startMethod.Replace($queryLine, $queryLine + "`r`n            lastQuery = query;")

    $failureLine = '        if (!ignoreFailure) throw new InvalidOperationException("Windows protection service did not reach RUNNING state.");'
    if (-not $startMethod.Contains($failureLine)) { throw 'V7 generic service start failure line not found.' }
    $failureBlock = @'
        if (!ignoreFailure)
        {
            var startDetail = result.Combined.Trim();
            var queryDetail = lastQuery?.Combined.Trim() ?? "no service query result";
            var eventResult = await ProcessRunner.RunAsync(
                "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                "$cutoff=(Get-Date).AddMinutes(-3); Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$cutoff} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -in @('.NET Runtime','Application Error','Windows Error Reporting') -or $_.Message -like '*DKLock.Service*' } | Select-Object -First 12 TimeCreated,ProviderName,Id,LevelDisplayName,Message | Format-List | Out-String -Width 4096");
            var eventDetail = eventResult.Combined.Trim();
            throw new InvalidOperationException($"Windows protection service did not reach RUNNING state. sc-start-exit={result.ExitCode}; sc-start={startDetail}; last-query={queryDetail}; recent-events={eventDetail}");
        }
'@
    $startMethod = $startMethod.Replace($failureLine, $failureBlock.TrimEnd())
    $installer = $installer.Remove($startMatch.Index, $startMatch.Length).Insert($startMatch.Index, $startMethod)
}
if ($installer -notmatch 'recent-events=') { throw 'V7 service crash event diagnostics were not applied.' }

# Guardrails: the repair path must no longer rename InstallRoot, the rollback snapshot must be
# outside Program Files, and strict post-install payload verification from the prior V7 fix remains.
if ($installer -match 'Directory\.Move\(_options\.InstallRoot, rollback\)') {
    throw 'Unsafe Program Files root rename still exists in V7 repair transaction.'
}
if ($installer -notmatch 'Path\.Combine\(Path\.GetTempPath\(\), \$"dklock-v7-rollback-') {
    throw 'V7 temp rollback snapshot was not applied.'
}
if ($installer -notmatch 'VerifyInstalledDirectory\(_options\.InstallRoot\);') {
    throw 'Strict V7 installed-directory integrity verification is missing.'
}
if ($installer -match 'allowedExtraFiles|allowedExtras') {
    throw 'V7 payload integrity validator was unexpectedly relaxed.'
}
Set-Content $installerPath $installer -Encoding utf8

# The original V7 static validator encoded the old sibling Directory.Move implementation as two
# literal implementation tokens. Replace only those exact assertions with the safer transaction
# markers. Functional Gate 11 still performs the real repair and encrypted-data persistence test.
$validatorPath = Join-Path $Root 'tests/validate_v7.py'
if (-not (Test-Path $validatorPath)) { throw "Missing V7 static validator: $validatorPath" }
$validator = Get-Content $validatorPath -Raw
if ($validator -notmatch '\.rollback-' -or $validator -notmatch 'Directory\.Move') {
    throw 'Expected legacy V7 repair implementation assertions were not found.'
}
$validator = $validator.Replace('".rollback-"', '"dklock-v7-rollback-"')
$validator = $validator.Replace("'.rollback-'", "'dklock-v7-rollback-'")
$validator = $validator.Replace('"Directory.Move"', '"ClearDirectory"')
$validator = $validator.Replace("'Directory.Move'", "'ClearDirectory'")
if ($validator -match '(["''])\.rollback-\1' -or $validator -match '(["''])Directory\.Move\1') {
    throw 'Legacy V7 repair static assertions remain after validator update.'
}
if ($validator -notmatch 'dklock-v7-rollback-' -or $validator -notmatch 'ClearDirectory') {
    throw 'ACL-safe V7 repair static assertions were not installed.'
}
Set-Content $validatorPath $validator -Encoding utf8

Write-Host 'Applied V7 ACL-safe transactional repair, aligned static assertions, and service crash diagnostics.'
