param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'

$guiSource = Join-Path $PSScriptRoot 'v10-window-lock-e2e.ps1'
$guiTarget = Join-Path $Root 'scripts/test-v10-window-lock-e2e.ps1'
if (-not (Test-Path $guiSource)) { throw "Missing V10 GUI E2E harness: $guiSource" }
$guiHash = (Get-FileHash $guiSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ($guiHash -ne '0b7863460f24e0f519d2f121938f52c0d5cd87d400cc5fdc0dbd80c072f3ee81') { throw "V10 GUI E2E harness SHA mismatch: $guiHash" }
Copy-Item $guiSource $guiTarget -Force

$probe = Join-Path $Root 'tools/DKLock.V10.Probe/Program.cs'
$probeText = Get-Content $probe -Raw
$probeText = $probeText.Replace('usage: <ping|service-e2e|retired> <pipe> [master] [pin]', 'usage: <ping|add-app|service-e2e|retired> <pipe> [args]')
if ($probeText -notmatch 'command == "add-app"') {
    $anchor = '    if (command == "service-e2e")'
    if (-not $probeText.Contains($anchor)) { throw 'V10 probe service-e2e anchor missing.' }
    $addApp = @'
    if (command == "add-app")
    {
        if (args.Length < 4) return 2;
        var target = Path.GetFullPath(args[2]);
        var displayName = args[3];
        var apps = await client.GetApplicationsAsync();
        Require(apps.Success, "application list available for GUI E2E registration");
        var existing = apps.Applications?.FirstOrDefault(x => string.Equals(Path.GetFullPath(x.ExecutablePath), target, StringComparison.OrdinalIgnoreCase));
        if (existing is null)
        {
            var add = await client.AddApplicationAsync(target, displayName, true);
            Require(add.Success, "GUI E2E target added as protected application");
        }
        else if (!existing.Enabled)
        {
            var enable = await client.SetApplicationEnabledAsync(existing.Id, true);
            Require(enable.Success, "GUI E2E target protection enabled");
        }
        Console.WriteLine("RESULT: PASS");
        return 0;
    }

'@
    $probeText = $probeText.Replace($anchor, $addApp + $anchor)
    Set-Content $probe -Value $probeText -Encoding utf8
}

$gate = Join-Path $Root 'scripts/test-v10.ps1'
$gateText = Get-Content $gate -Raw
$serviceLine = '    Invoke-External "[8/10] real Service/IPC application-lifetime security E2E" { dotnet run --project .\tools\DKLock.V10.Probe\DKLock.V10.Probe.csproj -c Release --no-build -- service-e2e $pipeName $master $pin }'
if ($gateText -notmatch 'real GUI/window overlay E2E') {
    if (-not $gateText.Contains($serviceLine)) { throw 'V10 service E2E invocation anchor missing.' }
    $guiLine = '    Invoke-External "      real GUI/window overlay E2E" { & .\scripts\test-v10-window-lock-e2e.ps1 -Root $root -InstallRoot $installRoot -PipeName $pipeName -MasterPassword $master }'
    $gateText = $gateText.Replace($serviceLine, $serviceLine + "`r`n" + $guiLine)
}

$reportAnchor = "'- PASS: RAM-only UntilApplicationClose release/reopen lifecycle',"
if ($gateText -notmatch 'real GUI overlay disables the protected target HWND') {
    if (-not $gateText.Contains($reportAnchor)) { throw 'V10 report lifecycle anchor missing.' }
    $guiReport = @"
$reportAnchor
'- PASS: real GUI overlay disables the protected target HWND before authentication',
'- PASS: real GUI overlay matches target outer-window geometry and is not global TopMost',
'- PASS: wrong password keeps the real target locked; correct Master Password unlocks it',
'- PASS: closing the last visible window while process remains alive clears authorization; reopening relocks',
"@
    $gateText = $gateText.Replace($reportAnchor, $guiReport.TrimEnd())
}

if ($gateText -notmatch '(?m)^exit 0\s*$') {
    $successTail = 'Write-Host "=== ALL DK LOCK V10 PRODUCTION GATES PASS ==="'
    if (-not $gateText.Contains($successTail)) { throw 'V10 production success tail missing.' }
    $gateText = $gateText.Replace($successTail, $successTail + "`r`n`$global:LASTEXITCODE = 0`r`nexit 0")
}
Set-Content $gate -Value $gateText -Encoding utf8

foreach ($script in @($gate, $guiTarget)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -ne 0) {
        $messages = ($errors | ForEach-Object Message) -join '; '
        throw "PowerShell parse failure in ${script}: $messages"
    }
}

Write-Host "Wired real V10 window-lock GUI E2E SHA256=$guiHash, GUI target registration, runtime evidence/reporting, and deterministic success exit code."
