param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'

$guiSource = Join-Path $PSScriptRoot 'v10-window-lock-e2e.ps1'
$guiTarget = Join-Path $Root 'scripts/test-v10-window-lock-e2e.ps1'
if (-not (Test-Path $guiSource)) { throw "Missing V10 GUI E2E harness: $guiSource" }
$guiHash = (Get-FileHash $guiSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ($guiHash -ne '96cbe071808d007a9bdb76bac84b5da9458a6afd6d03f1ad512bb85177a3ddf1') { throw "V10 GUI E2E harness SHA mismatch: $guiHash" }
Copy-Item $guiSource $guiTarget -Force

# The deterministic WinForms target must keep wait registrations alive for the
# whole message loop. RegisteredWaitHandle is not IDisposable on .NET 8, so
# unregister explicitly after Application.Run returns.
$guiText = Get-Content $guiTarget -Raw
$guiText = $guiText.Replace('using var showReg = ThreadPool.RegisterWaitForSingleObject', 'var showReg = ThreadPool.RegisterWaitForSingleObject')
$guiText = $guiText.Replace('using var exitReg = ThreadPool.RegisterWaitForSingleObject', 'var exitReg = ThreadPool.RegisterWaitForSingleObject')
$runMarker = 'Application.Run(form);'
if (-not $guiText.Contains($runMarker)) { throw 'V10 GUI target message-loop marker missing.' }
$guiText = $guiText.Replace($runMarker, $runMarker + "`r`nshowReg.Unregister(null);`r`nexitReg.Unregister(null);")

# Compare geometry using the same visible outer-frame contract as the product.
# GetWindowRect includes invisible resize borders on modern Windows; DK LOCK
# intentionally uses DWMWA_EXTENDED_FRAME_BOUNDS for the visible application frame.
$rectPInvoke = '[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);'
if (-not $guiText.Contains($rectPInvoke)) { throw 'V10 GUI geometry P/Invoke anchor missing.' }
$guiText = $guiText.Replace(
    $rectPInvoke,
    $rectPInvoke + "`r`n" + '  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT rect, int size);' + "`r`n" + '  public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;')
$getRectPattern = '(?s)function Get-Rect\(\[IntPtr\]\$Hwnd\) \{.*?\n\}'
if ($guiText -notmatch $getRectPattern) { throw 'V10 GUI Get-Rect anchor missing.' }
$getRectReplacement = @'
function Get-Rect([IntPtr]$Hwnd) {
    $raw = New-Object V10Win32Probe+RECT
    if (-not [V10Win32Probe]::GetWindowRect($Hwnd, [ref]$raw)) { throw "GetWindowRect failed for $Hwnd" }
    $visual = New-Object V10Win32Probe+RECT
    $dwm = [V10Win32Probe]::DwmGetWindowAttribute($Hwnd, [V10Win32Probe]::DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$visual, 16)
    if ($dwm -eq 0 -and $visual.Right -gt $visual.Left -and $visual.Bottom -gt $visual.Top) { return $visual }
    return $raw
}
'@
$guiText = [regex]::Replace($guiText, $getRectPattern, $getRectReplacement.TrimEnd(), 1)
Set-Content $guiTarget -Value $guiText -Encoding utf8

# E2E-only agent trace. It is inert unless DKLOCK_V10_AGENT_TRACE is set.
$agent = Join-Path $Root 'src/DKLock.App/Protection/ApplicationWindowProtectionAgent.cs'
$agentText = Get-Content $agent -Raw
if ($agentText -notmatch 'V10AgentTrace') {
    $propertyAnchor = '    public int ProtectedWindowCount => _windows.Count;'
    if (-not $agentText.Contains($propertyAnchor)) { throw 'V10 agent trace property anchor missing.' }
    $traceHelper = @'
    private static void V10AgentTrace(string message)
    {
        var path = Environment.GetEnvironmentVariable("DKLOCK_V10_AGENT_TRACE");
        if (string.IsNullOrWhiteSpace(path)) return;
        try
        {
            File.AppendAllText(path, $"{DateTimeOffset.UtcNow:O} pid={Environment.ProcessId} {message}{Environment.NewLine}");
        }
        catch { }
    }

'@
    $agentText = $agentText.Replace($propertyAnchor, $traceHelper + $propertyAnchor)
    $agentText = $agentText.Replace('        _started = true;', '        _started = true;' + "`r`n" + '        V10AgentTrace("StartAsync begin");')
    $agentText = $agentText.Replace('        await RefreshPoliciesAsync(cancellationToken);', '        await RefreshPoliciesAsync(cancellationToken);' + "`r`n" + '        V10AgentTrace($"policies={_enabledPolicies.Count}");')
    $agentText = $agentText.Replace('        InstallHooks();', '        InstallHooks();' + "`r`n" + '        V10AgentTrace($"hooks={_hooks.Count}");')
    $agentText = $agentText.Replace('        await ReconcileVisibleWindowsAsync(requestFocusForForeground: true);', '        await ReconcileVisibleWindowsAsync(requestFocusForForeground: true);' + "`r`n" + '        V10AgentTrace($"initial_windows={_windows.Count}");')
    $normalizeAnchor = '        try { normalized = ApplicationPath.Normalize(path); }' + "`r`n" + '        catch { return; }'
    if (-not $agentText.Contains($normalizeAnchor)) {
        $normalizeAnchor = '        try { normalized = ApplicationPath.Normalize(path); }' + "`n" + '        catch { return; }'
    }
    if (-not $agentText.Contains($normalizeAnchor)) { throw 'V10 agent normalize trace anchor missing.' }
    $agentText = $agentText.Replace($normalizeAnchor, $normalizeAnchor + "`r`n" + '        V10AgentTrace($"observe hwnd={hwnd} pid={processId} path={normalized} visible={NativeWindowMethods.IsWindowVisible(hwnd)} iconic={NativeWindowMethods.IsIconic(hwnd)}");')
    $policyMiss = '        if (!TryGetProtectedPolicy(normalized, out var policy) || policy is null)' + "`r`n" + '        {'
    if (-not $agentText.Contains($policyMiss)) {
        $policyMiss = '        if (!TryGetProtectedPolicy(normalized, out var policy) || policy is null)' + "`n" + '        {'
    }
    if (-not $agentText.Contains($policyMiss)) { throw 'V10 agent policy trace anchor missing.' }
    $agentText = $agentText.Replace($policyMiss, $policyMiss + "`r`n" + '            V10AgentTrace($"not_protected path={normalized} policies={_enabledPolicies.Count}");')
    $cancelAnchor = '        CancelPendingRelease(normalized);'
    $agentText = $agentText.Replace($cancelAnchor, '        V10AgentTrace($"protected path={normalized} display={policy.DisplayName}");' + "`r`n" + $cancelAnchor)
    $incomingAnchor = '        var incoming = response.Items' + "`r`n" + '            .Where(x => x.Enabled)' + "`r`n" + '            .ToDictionary(x => ApplicationPath.Normalize(x.ExecutablePath), StringComparer.OrdinalIgnoreCase);'
    if (-not $agentText.Contains($incomingAnchor)) {
        $incomingAnchor = '        var incoming = response.Items' + "`n" + '            .Where(x => x.Enabled)' + "`n" + '            .ToDictionary(x => ApplicationPath.Normalize(x.ExecutablePath), StringComparer.OrdinalIgnoreCase);'
    }
    if (-not $agentText.Contains($incomingAnchor)) { throw 'V10 agent incoming-policy trace anchor missing.' }
    $agentText = $agentText.Replace($incomingAnchor, $incomingAnchor + "`r`n" + '        V10AgentTrace($"refresh_response success={response.Success} enabled={incoming.Count}");')
    Set-Content $agent -Value $agentText -Encoding utf8
}

# Route the E2E trace into the runtime evidence directory and include it on failure.
$traceInject = '$reportDir = Join-Path $Root ''report\runtime'''
$guiText = Get-Content $guiTarget -Raw
if ($guiText -notmatch 'DKLOCK_V10_AGENT_TRACE') {
    if (-not $guiText.Contains($traceInject)) { throw 'V10 GUI report directory anchor missing for trace.' }
    $guiText = $guiText.Replace(
        $traceInject,
        $traceInject + "`r`n" + '$agentTrace = Join-Path $reportDir ''V10_AGENT_TRACE.txt''' + "`r`n" + '$oldAgentTrace = $env:DKLOCK_V10_AGENT_TRACE' + "`r`n" + '$env:DKLOCK_V10_AGENT_TRACE = $agentTrace')
    $catchAnchor = 'catch {' + "`r`n" + '    $lines.Add("FAIL: $($_.Exception.Message)")'
    if (-not $guiText.Contains($catchAnchor)) {
        $catchAnchor = 'catch {' + "`n" + '    $lines.Add("FAIL: $($_.Exception.Message)")'
    }
    if (-not $guiText.Contains($catchAnchor)) { throw 'V10 GUI catch trace anchor missing.' }
    $catchReplacement = $catchAnchor + "`r`n" + '    if (Test-Path $agentTrace) { $lines.Add(''AGENT TRACE:''); $lines.AddRange([string[]](Get-Content $agentTrace)) }'
    $guiText = $guiText.Replace($catchAnchor, $catchReplacement)
    $restoreAnchor = '    if ($null -eq $oldPipe) { Remove-Item Env:DKLOCK_PIPE_NAME -ErrorAction SilentlyContinue } else { $env:DKLOCK_PIPE_NAME = $oldPipe }'
    if (-not $guiText.Contains($restoreAnchor)) { throw 'V10 GUI env restore anchor missing.' }
    $guiText = $guiText.Replace($restoreAnchor, $restoreAnchor + "`r`n" + '    if ($null -eq $oldAgentTrace) { Remove-Item Env:DKLOCK_V10_AGENT_TRACE -ErrorAction SilentlyContinue } else { $env:DKLOCK_V10_AGENT_TRACE = $oldAgentTrace }')
    Set-Content $guiTarget -Value $guiText -Encoding utf8
}

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

Write-Host "Wired real V10 window-lock GUI E2E SHA256=$guiHash, fixed .NET 8 wait-registration lifetime, GUI target registration, runtime evidence/reporting, and deterministic success exit code."
