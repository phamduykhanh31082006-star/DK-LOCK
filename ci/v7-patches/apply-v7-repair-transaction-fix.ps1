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

$oldRestore = @'
                TryDeleteDirectory(_options.InstallRoot);
                if (rollback is not null && Directory.Exists(rollback)) Directory.Move(rollback, _options.InstallRoot);
'@
if (-not $installer.Contains($oldRestore.Trim())) {
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
$installer = $installer.Replace($oldRestore.Trim(), $newRestore.Trim())

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
Write-Host 'Applied V7 ACL-safe transactional repair rollback snapshot.'
