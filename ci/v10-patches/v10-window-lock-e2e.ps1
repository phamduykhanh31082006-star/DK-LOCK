param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [Parameter(Mandatory=$true)][string]$PipeName,
    [Parameter(Mandatory=$true)][string]$MasterPassword
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class V10Win32Probe {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
  public const uint WM_CLOSE = 0x0010;
  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_TOPMOST = 0x00000008;
}
'@

function Wait-Until([scriptblock]$Predicate, [int]$TimeoutMs = 10000, [int]$PollMs = 100) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Predicate) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

function Get-VisibleWindowForPid([int]$ProcessId, [IntPtr]$Exclude = [IntPtr]::Zero) {
    $found = [IntPtr]::Zero
    $callback = [V10Win32Probe+EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$lParam)
        [uint32]$owner = 0
        [void][V10Win32Probe]::GetWindowThreadProcessId($hwnd, [ref]$owner)
        if ($owner -eq $ProcessId -and $hwnd -ne $Exclude -and [V10Win32Probe]::IsWindowVisible($hwnd)) {
            $script:foundWindow = $hwnd
            return $false
        }
        return $true
    }
    $script:foundWindow = [IntPtr]::Zero
    [void][V10Win32Probe]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:foundWindow
}

function Get-Rect([IntPtr]$Hwnd) {
    $r = New-Object V10Win32Probe+RECT
    if (-not [V10Win32Probe]::GetWindowRect($Hwnd, [ref]$r)) { throw "GetWindowRect failed for $Hwnd" }
    return $r
}

function Require([bool]$Condition, [string]$Message, [System.Collections.Generic.List[string]]$Lines) {
    if (-not $Condition) { throw $Message }
    $Lines.Add("PASS: $Message")
    Write-Host "PASS: $Message"
}

function Set-OverlaySecretAndInvoke([IntPtr]$OverlayHwnd, [string]$Secret) {
    $rootElement = [System.Windows.Automation.AutomationElement]::FromHandle($OverlayHwnd)
    if ($null -eq $rootElement) { throw 'Unable to bind UI Automation to V10 overlay.' }
    $edit = $rootElement.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit))
    if ($null -eq $edit) { throw 'V10 overlay password editor was not found by UI Automation.' }
    $valuePattern = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $valuePattern.SetValue($Secret)
    $buttonCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            'Unlock'))
    $unlock = $rootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    if ($null -eq $unlock) { throw 'V10 overlay Unlock button was not found by UI Automation.' }
    $invoke = $unlock.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invoke.Invoke()
}

$reportDir = Join-Path $Root 'report\runtime'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('DK LOCK V10 REAL WINDOW LOCK E2E')
$lines.Add("UTC: $([DateTimeOffset]::UtcNow.ToString('O'))")
$token = [Guid]::NewGuid().ToString('N').Substring(0,10)
$targetRoot = Join-Path $env:RUNNER_TEMP "dklock-v10-window-target-$token"
$outDir = Join-Path $targetRoot 'out'
New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

$project = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <UseWindowsForms>true</UseWindowsForms>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>DKLockV10WindowTarget</AssemblyName>
  </PropertyGroup>
</Project>
'@
$program = @'
using System.Threading;
using System.Windows.Forms;

ApplicationConfiguration.Initialize();
var token = args.Length > 0 ? args[0] : "default";
using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\DKLock.V10.WindowTarget.Show." + token);
using var exitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\DKLock.V10.WindowTarget.Exit." + token);
var exiting = false;
var form = new Form
{
    Text = "V10 Profile Chooser Test",
    Width = 860,
    Height = 620,
    StartPosition = FormStartPosition.Manual,
    Left = 120,
    Top = 100
};
var title = new Label { Dock = DockStyle.Top, Height = 100, TextAlign = ContentAlignment.MiddleCenter, Text = "Choose your profile", Font = new Font("Segoe UI", 24, FontStyle.Bold) };
var profile = new Button { Width = 300, Height = 80, Left = 270, Top = 210, Text = "Profile A" };
form.Controls.Add(profile);
form.Controls.Add(title);
form.FormClosing += (_, e) =>
{
    if (exiting) return;
    e.Cancel = true;
    form.Hide();
};
using var showReg = ThreadPool.RegisterWaitForSingleObject(showEvent, (_, _) =>
{
    try { form.BeginInvoke(new Action(() => { form.Show(); form.WindowState = FormWindowState.Normal; form.Activate(); })); } catch { }
}, null, Timeout.Infinite, false);
using var exitReg = ThreadPool.RegisterWaitForSingleObject(exitEvent, (_, _) =>
{
    try { form.BeginInvoke(new Action(() => { exiting = true; form.Close(); })); } catch { }
}, null, Timeout.Infinite, false);
Application.Run(form);
'@
Set-Content (Join-Path $targetRoot 'DKLockV10WindowTarget.csproj') $project -Encoding utf8
Set-Content (Join-Path $targetRoot 'Program.cs') $program -Encoding utf8

dotnet publish (Join-Path $targetRoot 'DKLockV10WindowTarget.csproj') -c Release -r win-x64 --self-contained false -o $outDir -p:TreatWarningsAsErrors=true
if ($LASTEXITCODE -ne 0) { throw "V10 window target build failed with $LASTEXITCODE" }
$targetExe = Join-Path $outDir 'DKLockV10WindowTarget.exe'
if (-not (Test-Path $targetExe)) { throw 'V10 window target executable missing.' }

$probeProject = Join-Path $Root 'tools\DKLock.V10.Probe\DKLock.V10.Probe.csproj'
dotnet run --project $probeProject -c Release --no-build -- add-app $PipeName $targetExe 'V10 E2E Target'
if ($LASTEXITCODE -ne 0) { throw 'Unable to register V10 GUI target as protected application.' }

$appExe = Join-Path $InstallRoot 'app\DKLock.exe'
if (-not (Test-Path $appExe)) { throw "Installed DK LOCK app missing: $appExe" }
$oldPipe = $env:DKLOCK_PIPE_NAME
$env:DKLOCK_PIPE_NAME = $PipeName
$appProcess = $null
$targetProcess = $null
$showHandle = $null
$exitHandle = $null
try {
    $appProcess = Start-Process -FilePath $appExe -ArgumentList @('--background','--lang','en-US') -PassThru
    Start-Sleep -Seconds 3
    Require (-not $appProcess.HasExited) 'background protection agent remains running' $lines

    $targetProcess = Start-Process -FilePath $targetExe -ArgumentList $token -PassThru
    Require (Wait-Until { $targetProcess.Refresh(); $targetProcess.MainWindowHandle -ne 0 } 10000) 'profile-like protected target window appeared' $lines
    $targetHwnd = [IntPtr]$targetProcess.MainWindowHandle

    $overlayHwnd = [IntPtr]::Zero
    Require (Wait-Until {
        $script:candidateOverlay = Get-VisibleWindowForPid -ProcessId $appProcess.Id
        if ($script:candidateOverlay -eq [IntPtr]::Zero) { return $false }
        $script:overlayCandidate = $script:candidateOverlay
        return $true
    } 10000) 'DK LOCK overlay appeared for the initial profile-like window' $lines
    $overlayHwnd = $script:overlayCandidate

    Require (-not [V10Win32Probe]::IsWindowEnabled($targetHwnd)) 'protected target HWND is disabled before authentication' $lines
    $targetRect = Get-Rect $targetHwnd
    $overlayRect = Get-Rect $overlayHwnd
    $positionDelta = [Math]::Abs($targetRect.Left - $overlayRect.Left) + [Math]::Abs($targetRect.Top - $overlayRect.Top)
    $sizeDelta = [Math]::Abs(($targetRect.Right-$targetRect.Left) - ($overlayRect.Right-$overlayRect.Left)) + [Math]::Abs(($targetRect.Bottom-$targetRect.Top) - ($overlayRect.Bottom-$overlayRect.Top))
    Require ($positionDelta -le 24 -and $sizeDelta -le 32) 'overlay covers the target outer window bounds within DPI/frame tolerance' $lines
    $exStyle = [V10Win32Probe]::GetWindowLong($overlayHwnd, [V10Win32Probe]::GWL_EXSTYLE)
    Require (($exStyle -band [V10Win32Probe]::WS_EX_TOPMOST) -eq 0) 'overlay is not globally topmost' $lines

    Set-OverlaySecretAndInvoke $overlayHwnd 'wrong-v10-ui-secret'
    Start-Sleep -Milliseconds 900
    Require ([V10Win32Probe]::IsWindow($overlayHwnd) -and [V10Win32Probe]::IsWindowVisible($overlayHwnd)) 'wrong password keeps overlay visible' $lines
    Require (-not [V10Win32Probe]::IsWindowEnabled($targetHwnd)) 'wrong password keeps target HWND disabled' $lines

    Set-OverlaySecretAndInvoke $overlayHwnd $MasterPassword
    Require (Wait-Until { [V10Win32Probe]::IsWindowEnabled($targetHwnd) } 8000) 'correct Master Password enables protected target HWND' $lines
    Require (Wait-Until { -not [V10Win32Probe]::IsWindow($overlayHwnd) -or -not [V10Win32Probe]::IsWindowVisible($overlayHwnd) } 8000) 'correct Master Password removes protection overlay' $lines

    [void][V10Win32Probe]::PostMessage($targetHwnd, [V10Win32Probe]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Require (Wait-Until { -not [V10Win32Probe]::IsWindowVisible($targetHwnd) } 5000) 'last visible protected window can close/hide after authorization' $lines
    Require (-not $targetProcess.HasExited) 'target process remains alive in background after last visible window closes' $lines
    Start-Sleep -Milliseconds 700

    $showHandle = [Threading.EventWaitHandle]::OpenExisting("Local\DKLock.V10.WindowTarget.Show.$token")
    [void]$showHandle.Set()
    Require (Wait-Until { $targetProcess.Refresh(); $targetProcess.MainWindowHandle -ne 0 -and [V10Win32Probe]::IsWindowVisible([IntPtr]$targetProcess.MainWindowHandle) } 8000) 'same background process reopened a visible protected window' $lines
    $targetHwnd = [IntPtr]$targetProcess.MainWindowHandle
    $relockOverlay = [IntPtr]::Zero
    Require (Wait-Until {
        $script:relockCandidate = Get-VisibleWindowForPid -ProcessId $appProcess.Id
        if ($script:relockCandidate -eq [IntPtr]::Zero) { return $false }
        $script:relockOverlayFound = $script:relockCandidate
        return -not [V10Win32Probe]::IsWindowEnabled($targetHwnd)
    } 10000) 'reopen after last visible window relocks even though process never exited' $lines
    $relockOverlay = $script:relockOverlayFound
    Require (-not [V10Win32Probe]::IsWindowEnabled($targetHwnd)) 'reopened target HWND is disabled until re-authentication' $lines
    Set-OverlaySecretAndInvoke $relockOverlay $MasterPassword
    Require (Wait-Until { [V10Win32Probe]::IsWindowEnabled($targetHwnd) } 8000) 're-authentication unlocks reopened target window' $lines

    $lines.Add('RESULT: PASS')
    $lines | Set-Content (Join-Path $reportDir 'V10_WINDOW_LOCK_E2E.txt') -Encoding utf8
    [pscustomobject]@{
        result = 'PASS'
        target = $targetExe
        initial_lock = $true
        wrong_password_remained_locked = $true
        master_password_unlocked = $true
        background_process_reopen_relocked = $true
        global_topmost = $false
    } | ConvertTo-Json | Set-Content (Join-Path $reportDir 'V10_WINDOW_LOCK_E2E.json') -Encoding utf8
}
catch {
    $lines.Add("FAIL: $($_.Exception.Message)")
    $lines.Add('RESULT: FAIL')
    $lines | Set-Content (Join-Path $reportDir 'V10_WINDOW_LOCK_E2E.txt') -Encoding utf8
    throw
}
finally {
    if ($showHandle) { $showHandle.Dispose() }
    if ($targetProcess -and -not $targetProcess.HasExited) {
        try {
            $exitHandle = [Threading.EventWaitHandle]::OpenExisting("Local\DKLock.V10.WindowTarget.Exit.$token")
            [void]$exitHandle.Set()
            if (-not $targetProcess.WaitForExit(3000)) { $targetProcess.Kill($true) }
        } catch { try { $targetProcess.Kill($true) } catch { } }
    }
    if ($exitHandle) { $exitHandle.Dispose() }
    if ($appProcess -and -not $appProcess.HasExited) { try { $appProcess.Kill($true) } catch { } }
    if ($null -eq $oldPipe) { Remove-Item Env:DKLOCK_PIPE_NAME -ErrorAction SilentlyContinue } else { $env:DKLOCK_PIPE_NAME = $oldPipe }
    Remove-Item $targetRoot -Recurse -Force -ErrorAction SilentlyContinue
}
