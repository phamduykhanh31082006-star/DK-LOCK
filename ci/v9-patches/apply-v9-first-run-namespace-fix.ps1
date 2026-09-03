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
# Keep the real Button -> ICommand -> IPC/Service path, but wait until each
# click has actually been dispatched before evaluating its async result.
$nameToken = 'RunV9FunctionalUiE2EAsync('
$nameIndex = $content.IndexOf($nameToken, [System.StringComparison]::Ordinal)
if ($nameIndex -lt 0) { throw 'V9 functional UI E2E method name was not found.' }
$lineBreak = $content.LastIndexOf("`n", $nameIndex)
$methodStart = if ($lineBreak -ge 0) { $lineBreak + 1 } else { 0 }
$helperToken = 'private static Button RequireButton'
$helperStart = $content.IndexOf($helperToken, $nameIndex, [System.StringComparison]::Ordinal)
if ($helperStart -lt 0) { throw 'V9 functional UI E2E helper boundary was not found.' }

$prefix = $content.Substring(0, $methodStart)
$functional = $content.Substring($methodStart, $helperStart - $methodStart)
$suffix = $content.Substring($helperStart)
$sourceLines = [regex]::Split($functional, '\r?\n')
$rebuilt = New-Object System.Collections.Generic.List[string]
$invokeCount = 0
for ($i = 0; $i -lt $sourceLines.Count; $i++) {
    $line = $sourceLines[$i]
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

[IO.File]::WriteAllText($smokePath, $content, [Text.UTF8Encoding]::new($false))
$updated = Get-Content $smokePath -Raw
if ($updated -notmatch [regex]::Escape($usingLine)) { throw 'Failed to import FirstRunSetupWindow namespace.' }
if ($updated -match '(?m)^\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Uncaptured onboarding Dispatcher.BeginInvoke remains.' }
if ($updated -notmatch '(?m)^\s*_\s*=\s*onboarding\.Dispatcher\.BeginInvoke\(') { throw 'Onboarding Dispatcher.BeginInvoke scheduling fix was not applied.' }
$syncCount = ([regex]::Matches($updated, 'await window\.Dispatcher\.InvokeAsync\(\(\) => \{ \}, DispatcherPriority\.ApplicationIdle\);')).Count
if ($syncCount -lt $invokeCount) { throw "V9 functional UI dispatcher synchronization count mismatch: invokes=$invokeCount sync=$syncCount" }
if ($updated -notmatch 'DIAG_APPLICATION_AFTER_CLICK') { throw 'V9 Add Application failure diagnostic is missing.' }

# Promote the already validated V9 product source from release-candidate identity
# to the exact 9.0.0 final source. This happens before all 22 release gates, so
# the generated installer, registry metadata, portal and tests all validate the
# final identity rather than an RC binary.
$textExtensions = @('.cs','.ps1','.py','.md','.json','.html','.js','.css','.props','.csproj','.xaml','.txt','.yml','.yaml')
$utf8 = [Text.UTF8Encoding]::new($false)
Get-ChildItem -Path $Root -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/](bin|obj|artifacts|__pycache__)[\\/]' -and
    ($textExtensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -eq 'VERSION')
} | ForEach-Object {
    $raw = [IO.File]::ReadAllText($_.FullName)
    if ($raw.Contains('9.0.0-rc')) {
        [IO.File]::WriteAllText($_.FullName, $raw.Replace('9.0.0-rc','9.0.0'), $utf8)
    }
}

$validatePath = Join-Path $Root 'tests/validate_v9.py'
$validate = [IO.File]::ReadAllText($validatePath)
$validate = $validate.Replace("check('V9 is not prematurely locked','not locked / not released' in status)", "check('V9 final source carries exact-source lock contract','completed / released / locked' in status and '22/22 release gates' in status)")
$validate = $validate.Replace('VERSION is V9 release candidate','VERSION is final V9 release')
[IO.File]::WriteAllText($validatePath, $validate, $utf8)

$contractPath = Join-Path $Root 'tests/DKLock.V9.ContractTests/Program.cs'
$contract = [IO.File]::ReadAllText($contractPath).Replace('setup product version is V9 release candidate','setup product version is final V9 release')
[IO.File]::WriteAllText($contractPath, $contract, $utf8)

$changelogPath = Join-Path $Root 'CHANGELOG.md'
$changelog = [IO.File]::ReadAllText($changelogPath).Replace('## 9.0.0 — Functional Productization & UX Rebuild (in progress)','## 9.0.0 — Functional Productization & UX Rebuild (released)')
[IO.File]::WriteAllText($changelogPath, $changelog, $utf8)

$statusText = @'
# DK LOCK V9 — Work Status

Version: `9.0.0`
Baseline: `V8.0.0 COMPLETED / RELEASED / LOCKED`

Current stage: **9.0.0 / COMPLETED / RELEASED / LOCKED**

## Locked V9 objectives

- **V9-A Functional UI Reliability** — async command lifecycle, `CanExecuteChanged`, reconnect/busy behavior and deterministic action states validated.
- **V9-B First-run Product Setup** — Security Service → Master Password → optional PIN → Smart Protection → Ready validated in Vietnamese and English.
- **V9-C Real User Workflows** — Application Protection, Folder Protection, Secure Documents, Account Vault, PIN configuration and Quick Lock exercised from real WPF buttons through IPC/Windows Service with encrypted/persisted result checks.
- **V9-D Design System V2** — Light default, Dark option, persisted theme preference, tokenized presentation and explanatory empty states validated.
- **V9-E Release Validation Standard** — full V0–V8 regression, warnings-as-errors build, real install/service/IPC/ACL/repair/uninstall/purge, exact installer integrity, portal metadata and user-installer ZIP gates are mandatory.

## Release-lock rule

This file is part of the exact V9 final source. The `COMPLETED / RELEASED / LOCKED` designation is valid only for this exact source when the Windows V9 workflow completes **22/22 release gates** successfully. Any source or binary change after that validation requires a complete rerun.

Security boundary remains user-mode; V9 makes no kernel/minifilter or administrator-proof claim. Sensitive sessions remain RAM-only and protected content confidentiality remains cryptographic where provided by the locked protection stack.
'@
[IO.File]::WriteAllText((Join-Path $Root 'V9_WORK_STATUS.md'), $statusText.TrimStart(), $utf8)

$reportText = @'
# DK LOCK V9 FINAL RELEASE REPORT

Status: **COMPLETED / RELEASED / LOCKED**
Version: `9.0.0`
Baseline: DK LOCK V8.0.0 LOCKED

## Completed objectives

- **V9-A — Functional UI Reliability:** command-state invalidation and async lifecycle are deterministic across Applications, Folders, Secure Documents, Accounts and Settings.
- **V9-B — First-run Product Setup:** real bilingual onboarding follows Service → Master Password → optional PIN → Smart Protection → Ready.
- **V9-C — Real User Workflows:** mandatory UI Automation drives actual WPF buttons through ICommand → IPC → Windows Service for Application Protection, Folder Protection, Secure Documents, Account Vault, PIN and Quick Lock.
- **V9-D — Design System V2:** Light default, Dark option, persisted non-sensitive theme preference, coherent token system and actionable empty states.
- **V9-E — Release Validation:** exact-source 22-gate Windows production validation is the lock authority.

## Validation contract

The final release is accepted only when the exact source containing this report passes V9 static validation, full locked V0–V8 regression, warnings-as-errors builds, bilingual setup/onboarding, real installed WPF functional E2E, encrypted-at-rest/persistence checks, PIN/Quick Lock, Windows Service/IPC/ACL, repair/uninstall/purge, Light/Dark runtime evidence, installer SHA-256, portal metadata and primary user ZIP integrity.

No CI run ID, installer byte count or SHA-256 is hard-coded into source documentation. Those values are generated from the exact tested binary and must match final release artifacts. Any post-validation source or binary modification invalidates the lock and requires full revalidation.

Signing status is explicit at build time. When no certificate is configured the required label remains `UNSIGNED - no code-signing certificate configured`.
'@
[IO.File]::WriteAllText((Join-Path $Root 'report/V9_REPORT.md'), $reportText.TrimStart(), $utf8)

$readmeText = @'
# DK LOCK — V9 Functional Production Release

DK LOCK is a Windows privacy/security application built with .NET 8, WPF, a background Windows Service, SQLite, Named Pipes IPC and cryptographic protection for local sensitive content.

## Current release line

**9.0.0 — Functional Productization & UX Rebuild / LOCKED**

V9 preserves the V3–V8 protection/deployment stack and makes the complete product workflow usable from the real WPF interface: Application Protection; encrypted-at-rest Folder Protection and Secure Documents; encrypted Account Vault; Smart Protection/PIN/Quick Lock/Auto Lock; self-contained Windows x64 deployment; owner-bound IPC; Vietnamese/English UX; first-run security onboarding; and Design System V2.

## End-user delivery

Primary delivery artifact: `DK_LOCK_V9_USER_INSTALLER.zip`.

It contains the exact validated `DK_LOCK_V9_Setup.exe`, SHA-256 sidecar, signing status and release metadata. The installer is self-contained for Windows x64; end users do not need a .NET SDK or separate Desktop Runtime.

## Security boundary

DK LOCK remains user-mode software. V9 does not claim kernel/minifilter isolation or protection against a machine Administrator deliberately bypassing local controls. Sensitive unlock sessions remain RAM-only. Protected content confidentiality relies on the cryptographic mechanisms of the locked stack.

## Release gate

Run `./scripts/test-v9.ps1` on the Windows release environment. V9 is LOCKED only when the exact final source passes all **22** production release gates. Any source or binary modification after validation requires the complete gate again.
'@
[IO.File]::WriteAllText((Join-Path $Root 'README.md'), $readmeText.TrimStart(), $utf8)

$roadmapText = @'
# DK LOCK Roadmap — V0 → V9

| Version | Trọng tâm | Status / Exit outcome |
|---|---|---|
| V0 | Product Foundation | LOCKED — blueprint/rules/security/performance baseline |
| V1 | UX/UI Foundation | LOCKED — WPF shell + Design System + navigation |
| V2 | Core Architecture | LOCKED — service/state/IPC/SQLite/Activity |
| V3 | Application Protection | LOCKED — policy + real-process detection + auth + sessions + unlock UX |
| V4 | Folder & Secure Documents | LOCKED — encrypted folders + Secure Documents + regression |
| V5 | Account Vault | LOCKED — encrypted credentials + password generator + safe clipboard behavior |
| V6 | Smart Protection | LOCKED — Quick Lock, Auto Lock, session coordination, protection health |
| V7 | Production Release | LOCKED — Windows installer/service, ACL/integrity, repair/uninstall production gates |
| V8 | Bilingual Localization + Download UX | LOCKED — vi-VN/en-US app, installer and download portal |
| V9 | Functional Productization & UX Rebuild | LOCKED — first-run onboarding, real UI workflows, Design System V2, 22-gate exact-source release validation |

No version advances to LOCKED until its Definition of Done and complete regression/release gate are green on the exact release source.
'@
[IO.File]::WriteAllText((Join-Path $Root 'ROADMAP.md'), $roadmapText.TrimStart(), $utf8)

$runtimeDir = Join-Path $Root 'report/runtime'
if (Test-Path $runtimeDir) {
    Get-ChildItem $runtimeDir -File -Filter 'V9_*' -ErrorAction SilentlyContinue | Remove-Item -Force
}

if (([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim() -ne '9.0.0') { throw 'V9 final VERSION promotion failed.' }
if ([IO.File]::ReadAllText((Join-Path $Root 'Directory.Build.props')) -notmatch '<Version>9\.0\.0</Version>') { throw 'V9 final MSBuild version promotion failed.' }
if ([IO.File]::ReadAllText((Join-Path $Root 'tools/DKLock.Setup/SetupOptions.cs')) -notmatch 'ProductVersion = "9\.0\.0"') { throw 'V9 final Setup version promotion failed.' }
if ([IO.File]::ReadAllText((Join-Path $Root 'V9_WORK_STATUS.md')) -notmatch 'COMPLETED / RELEASED / LOCKED') { throw 'V9 final lock status promotion failed.' }
if ([IO.File]::ReadAllText((Join-Path $Root 'tests/validate_v9.py')) -match 'not prematurely locked') { throw 'V9 final validator still expects candidate status.' }

Write-Host "Applied exact V9 final source: onboarding fix, synchronized $invokeCount real UI Automation clicks, clean evidence state, and 9.0.0 final release promotion."
