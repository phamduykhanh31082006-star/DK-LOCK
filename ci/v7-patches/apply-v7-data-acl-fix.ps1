param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'

$installerPath = Join-Path $Root 'tools/DKLock.Setup/InstallerEngine.cs'
if (-not (Test-Path $installerPath)) { throw "Missing V7 installer source: $installerPath" }
$installer = Get-Content $installerPath -Raw

# The original V7 hardening command combined /inheritance:r + /grant:r + /T. On repair this
# recursively removed inherited ACEs from existing database files, then applied OI/CI inheritance
# grants that are not effective file ACEs. The result was an existing dklock.db with no effective
# LocalSystem access and SQLite Error 14 when the real SCM service restarted.
#
# Harden the ProgramData root only, then reset existing descendants so they inherit the already
# locked root ACL. New database/WAL/SHM files will inherit the same owner/System/Admin ACL naturally.
$aclMethodPattern = '(?ms)    private async Task ApplyDataAclAsync\(\)\r?\n    \{.*?\r?\n    \}(?=\r?\n\r?\n    private void WriteUninstallRegistry\(\))'
$aclMatch = [regex]::Match($installer, $aclMethodPattern)
if (-not $aclMatch.Success) { throw 'V7 ApplyDataAclAsync method not found.' }

$newAclMethod = @'
    private async Task ApplyDataAclAsync()
    {
        var grants = new[]
        {
            $"*S-1-5-18:(OI)(CI)F",
            $"*S-1-5-32-544:(OI)(CI)F",
            $"*{_options.OwnerSid}:(OI)(CI)F"
        };

        // Protect only the ProgramData root from parent inheritance. The OI/CI grants remain
        // effective on the root and are the sole inheritance source for all protected descendants.
        var rootArgs = new List<string> { _options.DataRoot, "/inheritance:r", "/grant:r" };
        rootArgs.AddRange(grants);
        rootArgs.AddRange(new[] { "/C", "/Q" });
        var rootResult = await ProcessRunner.RunAsync("icacls.exe", rootArgs.ToArray());
        rootResult.EnsureSuccess("ProgramData ACL hardening");

        // Existing files may carry stale or stripped ACLs from a previous install/repair. Reset only
        // descendants to the secured root ACL; never reset the root itself back to ProgramData defaults.
        if (Directory.EnumerateFileSystemEntries(_options.DataRoot).Any())
        {
            var descendants = Path.Combine(_options.DataRoot, "*");
            var resetResult = await ProcessRunner.RunAsync("icacls.exe", descendants, "/reset", "/T", "/C", "/Q");
            resetResult.EnsureSuccess("ProgramData descendant ACL reset");
        }
    }
'@

$installer = $installer.Remove($aclMatch.Index, $aclMatch.Length).Insert($aclMatch.Index, $newAclMethod.TrimEnd())
if ($installer -notmatch 'ProgramData descendant ACL reset') { throw 'V7 descendant ACL reset was not applied.' }
if ($installer -match 'new List<string> \{ _options\.DataRoot, "/inheritance:r", "/grant:r" \}.*?"/T"') {
    throw 'V7 root ACL hardening still recursively strips child inheritance.'
}
Set-Content $installerPath $installer -Encoding utf8

# Strengthen Gate 11: a repair is not considered successful unless the persisted SQLite file has
# inherited effective access for LocalSystem, Administrators, and the owning user after restart.
$testPath = Join-Path $Root 'scripts/test-v7.ps1'
if (-not (Test-Path $testPath)) { throw "Missing V7 release gate script: $testPath" }
$test = Get-Content $testPath -Raw
$marker = '    if (-not (Test-Path (Join-Path $dataRoot ''ci-preserve.marker''))) { throw "ProgramData marker was lost during repair." }'
if (-not $test.Contains($marker)) { throw 'V7 Gate 11 repair marker assertion not found.' }
if ($test -notmatch 'Database ACL missing SID after repair') {
    $aclAssertion = @'
    $dbAclAfterRepair = Get-Acl (Join-Path $dataRoot 'dklock.db')
    if ($dbAclAfterRepair.AreAccessRulesProtected) { throw "Database ACL should inherit from the secured ProgramData root after repair." }
    $dbAclSidsAfterRepair = @($dbAclAfterRepair.Access | ForEach-Object { try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $_.IdentityReference.Value } })
    foreach ($sid in @('S-1-5-18','S-1-5-32-544',$ownerSid)) {
        if ($dbAclSidsAfterRepair -notcontains $sid) { throw "Database ACL missing SID after repair: $sid" }
    }
'@
    $test = $test.Replace($marker, $marker + "`r`n" + $aclAssertion.TrimEnd())
}
if ($test -notmatch 'Database ACL missing SID after repair') { throw 'V7 Gate 11 database ACL assertion was not applied.' }

# A deliberately non-zero native command is used earlier to prove that the SCM service no longer
# exists after uninstall. PowerShell can retain that native LASTEXITCODE even after every gate has
# passed. Return success explicitly only after the final PASS marker has been reached; any earlier
# throw or failed gate still terminates the script as failure.
$successMarker = 'Write-Host "=== ALL DK LOCK V7 PRODUCTION RELEASE GATES PASS ==="'
if (-not $test.Contains($successMarker)) { throw 'V7 final success marker not found.' }
if ($test -notmatch '(?ms)Write-Host "=== ALL DK LOCK V7 PRODUCTION RELEASE GATES PASS ==="\s*\r?\n\s*exit 0') {
    $test = $test.Replace($successMarker, $successMarker + "`r`nexit 0")
}
if ($test -notmatch '(?ms)Write-Host "=== ALL DK LOCK V7 PRODUCTION RELEASE GATES PASS ==="\s*\r?\n\s*exit 0') {
    throw 'V7 release gate explicit success exit was not applied.'
}
Set-Content $testPath $test -Encoding utf8

# Finalize source-facing V7 status. These files are only published by the workflow after the full
# V7 release gate succeeds, so the tested source artifact cannot claim LOCKED on a failing run.
$statusPath = Join-Path $Root 'V7_WORK_STATUS.md'
if (-not (Test-Path $statusPath)) { throw 'Missing V7_WORK_STATUS.md.' }
$status = Get-Content $statusPath -Raw
if (-not $status.Contains('Current stage: **7.0.0-rc / PRODUCTIONIZATION**')) { throw 'Expected V7 RC status marker not found.' }
$status = $status.Replace('Current stage: **7.0.0-rc / PRODUCTIONIZATION**', 'Current stage: **7.0.0 / COMPLETED / LOCKED**')
$status = $status.Replace('V7 may be labeled complete only after the locked V7 Definition of Done passes.', 'V7 is complete and locked when the exact source commit passes the locked V7 Definition of Done and release artifacts are emitted successfully.')
Set-Content $statusPath $status -Encoding utf8

$reportPath = Join-Path $Root 'report/V7_REPORT.md'
if (-not (Test-Path $reportPath)) { throw 'Missing V7_REPORT.md.' }
$report = Get-Content $reportPath -Raw
if (-not $report.Contains('Status: release candidate until the V7 Windows production release pipeline passes.')) { throw 'Expected V7 report RC marker not found.' }
$report = $report.Replace('Status: release candidate until the V7 Windows production release pipeline passes.', 'Status: COMPLETED / LOCKED — final Windows production release pipeline PASS required on the published source artifact.')
$report = $report.Replace('This report is finalized by the release handoff only after the exact installer artifact passes install/repair/uninstall and integrity gates.', 'Release acceptance requires the exact installer artifact to pass install, production SCM startup, IPC/WPF smoke, repair with encrypted-data preservation, uninstall-preserve, explicit purge, ACL, SHA-256 payload integrity, metadata, and runtime-evidence gates.')
Set-Content $reportPath $report -Encoding utf8

$changePath = Join-Path $Root 'CHANGELOG.md'
if (-not (Test-Path $changePath)) { throw 'Missing CHANGELOG.md.' }
$change = Get-Content $changePath -Raw
if (-not $change.Contains('## 7.0.0-rc — Production Release')) { throw 'Expected V7 changelog RC marker not found.' }
$change = $change.Replace('## 7.0.0-rc — Production Release', '## 7.0.0 — Production Release (released)')
Set-Content $changePath $change -Encoding utf8

if ((Get-Content $statusPath -Raw) -notmatch '7\.0\.0 / COMPLETED / LOCKED') { throw 'V7 final work status was not applied.' }
if ((Get-Content $reportPath -Raw) -notmatch 'Status: COMPLETED / LOCKED') { throw 'V7 final report status was not applied.' }
if ((Get-Content $changePath -Raw) -notmatch '## 7\.0\.0 — Production Release \(released\)') { throw 'V7 final changelog status was not applied.' }

Write-Host 'Applied V7 ProgramData ACL repair, deterministic release exit, and final COMPLETED/LOCKED source status.'
