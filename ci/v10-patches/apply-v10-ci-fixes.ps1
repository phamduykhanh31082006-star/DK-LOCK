param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'

# Apply the unified, locally validated V10 target override to the reconstructed candidate.
$targetParts = @(Get-ChildItem (Join-Path $PSScriptRoot 'target.part*') | Sort-Object Name)
if ($targetParts.Count -ne 6) { throw "Expected 6 V10 target override parts, found $($targetParts.Count)." }
$targetRaw = ($targetParts | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$targetArchive = Join-Path $tempRoot 'v10-target-override.tar.xz'
[IO.File]::WriteAllBytes($targetArchive, [Convert]::FromBase64String($targetRaw))
$targetHash = (Get-FileHash $targetArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedTargetHash = 'b10af234bf91325a6a38c643c0cca149da4db094ea8f140bc8d1bbcd1abb22df'
if ($targetHash -ne $expectedTargetHash) { throw "V10 target override SHA mismatch: $targetHash" }
tar -xf $targetArchive -C $Root
if ($LASTEXITCODE -ne 0) { throw 'Failed to extract V10 target override.' }
Remove-Item $targetArchive -Force -ErrorAction SilentlyContinue

# Deterministic compile repairs retained after the recovered candidate was reconstructed.
$overlay = Join-Path $Root 'src/DKLock.App/Protection/ApplicationLockOverlayWindow.xaml'
if (-not (Test-Path $overlay)) { throw "Missing V10 overlay: $overlay" }
$text = Get-Content $overlay -Raw
$needle = '<Grid Background="{DynamicResource Brush.Window}">'
if ($text -like "*$needle*") {
    $text = $text.Replace($needle, '<Grid>')
    Set-Content -Path $overlay -Value $text -Encoding utf8
}

# Runtime XAML repair: the V10 overlay uses GhostButton for credential switching.
# The recovered V9 style dictionary did not define it, causing InitializeComponent()
# to throw at runtime and silently preventing every protection overlay from appearing.
$styles = Join-Path $Root 'src/DKLock.App/Resources/Styles.xaml'
if (-not (Test-Path $styles)) { throw "Missing V10 styles dictionary: $styles" }
$stylesText = Get-Content $styles -Raw
if ($stylesText -notmatch 'x:Key="GhostButton"') {
    $secondaryMarker = '    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">'
    if (-not $stylesText.Contains($secondaryMarker)) { throw 'V10 GhostButton insertion anchor missing.' }
    $ghostStyle = @'
    <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource Brush.Accent}"/>
        <Setter Property="BorderBrush" Value="Transparent"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

'@
    $stylesText = $stylesText.Replace($secondaryMarker, $ghostStyle + $secondaryMarker)
    Set-Content -Path $styles -Value $stylesText -Encoding utf8
}

# Runtime geometry repair: synchronize WPF device-independent bounds with the
# physical target HWND bounds before the final native z-order placement.
$overlayCodePath = Join-Path $Root 'src/DKLock.App/Protection/ApplicationLockOverlayWindow.xaml.cs'
if (-not (Test-Path $overlayCodePath)) { throw "Missing V10 overlay code-behind: $overlayCodePath" }
$overlayCode = Get-Content $overlayCodePath -Raw
if ($overlayCode -notmatch 'TransformFromDevice') {
    $oldPosition = @'
    private void Position(NativeWindowMethods.RECT bounds)
    {
        if (_overlayHandle == IntPtr.Zero) _overlayHandle = new WindowInteropHelper(this).Handle;
        if (_overlayHandle == IntPtr.Zero) return;

        var aboveTarget = NativeWindowMethods.GetWindow(_targetWindow, NativeWindowMethods.GW_HWNDPREV);
        var flags = NativeWindowMethods.SWP_NOACTIVATE;
        if (IsVisible) flags |= NativeWindowMethods.SWP_SHOWWINDOW;
        if (aboveTarget == _overlayHandle)
        {
            flags |= NativeWindowMethods.SWP_NOZORDER;
            aboveTarget = IntPtr.Zero;
        }
        NativeWindowMethods.SetWindowPos(
            _overlayHandle,
            aboveTarget == IntPtr.Zero ? NativeWindowMethods.HWND_TOP : aboveTarget,
            bounds.Left,
            bounds.Top,
            bounds.Width,
            bounds.Height,
            flags);
    }
'@
    $newPosition = @'
    private void Position(NativeWindowMethods.RECT bounds)
    {
        if (_overlayHandle == IntPtr.Zero) _overlayHandle = new WindowInteropHelper(this).Handle;
        if (_overlayHandle == IntPtr.Zero) return;

        SizeToContent = SizeToContent.Manual;
        var source = HwndSource.FromHwnd(_overlayHandle);
        var transform = source?.CompositionTarget?.TransformFromDevice;
        if (transform is not null)
        {
            var topLeft = transform.Value.Transform(new Point(bounds.Left, bounds.Top));
            var bottomRight = transform.Value.Transform(new Point(bounds.Right, bounds.Bottom));
            Left = topLeft.X;
            Top = topLeft.Y;
            Width = Math.Max(1d, bottomRight.X - topLeft.X);
            Height = Math.Max(1d, bottomRight.Y - topLeft.Y);
        }
        else
        {
            var dpi = VisualTreeHelper.GetDpi(this);
            var scaleX = dpi.DpiScaleX > 0d ? dpi.DpiScaleX : 1d;
            var scaleY = dpi.DpiScaleY > 0d ? dpi.DpiScaleY : 1d;
            Left = bounds.Left / scaleX;
            Top = bounds.Top / scaleY;
            Width = Math.Max(1d, bounds.Width / scaleX);
            Height = Math.Max(1d, bounds.Height / scaleY);
        }
        UpdateLayout();

        var aboveTarget = NativeWindowMethods.GetWindow(_targetWindow, NativeWindowMethods.GW_HWNDPREV);
        var flags = NativeWindowMethods.SWP_NOACTIVATE | NativeWindowMethods.SWP_SHOWWINDOW;
        if (aboveTarget == _overlayHandle)
        {
            flags |= NativeWindowMethods.SWP_NOZORDER;
            aboveTarget = IntPtr.Zero;
        }
        NativeWindowMethods.SetWindowPos(
            _overlayHandle,
            aboveTarget == IntPtr.Zero ? NativeWindowMethods.HWND_TOP : aboveTarget,
            bounds.Left,
            bounds.Top,
            bounds.Width,
            bounds.Height,
            flags);
    }
'@
    $positionPattern = '(?s)    private void Position\(NativeWindowMethods\.RECT bounds\)\s*\{.*?\n    \}\s*(?=\n    private async void UnlockButton_Click)'
    if ($overlayCode -notmatch $positionPattern) { throw 'V10 overlay Position method anchor missing.' }
    $overlayCode = [regex]::Replace($overlayCode, $positionPattern, $newPosition.TrimEnd(), 1)
    Set-Content -Path $overlayCodePath -Value $overlayCode -Encoding utf8
}

# WPF can perform one more desired-size layout pass immediately after Show(),
# which was shrinking the borderless overlay back to its content height.
# Complete layout first, then position again at Render priority using fresh DWM bounds.
$overlayCode = Get-Content $overlayCodePath -Raw
if ($overlayCode -notmatch '(?m)^using System\.Windows\.Media;\s*$') {
    $overlayCode = $overlayCode.Replace('using System.Windows.Interop;', "using System.Windows.Interop;`r`nusing System.Windows.Media;")
    Set-Content -Path $overlayCodePath -Value $overlayCode -Encoding utf8
}
$overlayCode = Get-Content $overlayCodePath -Raw
if ($overlayCode -notmatch 'DispatcherPriority\.Render') {
    if ($overlayCode -notmatch '(?m)^using System\.Windows\.Threading;\s*$') {
        $overlayCode = $overlayCode.Replace('using System.Windows.Interop;', "using System.Windows.Interop;`r`nusing System.Windows.Threading;")
    }
    $showPattern = '(?s)    public void ShowProtected\(bool requestFocus\)\s*\{.*?\n    \}\s*(?=\n    public void Reposition\(\))'
    if ($overlayCode -notmatch $showPattern) { throw 'V10 overlay ShowProtected method anchor missing.' }
    $showReplacement = @'
    public void ShowProtected(bool requestFocus)
    {
        if (!NativeWindowMethods.IsWindow(_targetWindow)) return;
        if (!NativeWindowMethods.TryGetWindowBoundsOnScreen(_targetWindow, out var bounds)) return;

        var firstShow = !IsVisible;
        if (firstShow)
        {
            if (_overlayHandle == IntPtr.Zero)
            {
                _overlayHandle = new WindowInteropHelper(this).EnsureHandle();
            }
            Position(bounds);
            Show();
            UpdateLayout();
        }

        Position(bounds);

        if (firstShow)
        {
            _ = Dispatcher.BeginInvoke(DispatcherPriority.Render, new Action(() =>
            {
                if (!IsVisible || !NativeWindowMethods.IsWindow(_targetWindow)) return;
                if (NativeWindowMethods.TryGetWindowBoundsOnScreen(_targetWindow, out var latestBounds))
                {
                    Position(latestBounds);
                }
            }));
        }

        if (requestFocus)
        {
            Activate();
            SecretBox.Focus();
            if (_overlayHandle != IntPtr.Zero) NativeWindowMethods.SetForegroundWindow(_overlayHandle);
        }
    }
'@
    $overlayCode = [regex]::Replace($overlayCode, $showPattern, $showReplacement.TrimEnd(), 1)
    Set-Content -Path $overlayCodePath -Value $overlayCode -Encoding utf8
}
$agent = Join-Path $Root 'src/DKLock.App/Protection/ApplicationWindowProtectionAgent.cs'
if (-not (Test-Path $agent)) { throw "Missing V10 protection agent: $agent" }
$agentText = Get-Content $agent -Raw
if ($agentText -notmatch '(?m)^using System\.IO;\s*$') {
    if ($agentText -notmatch '(?m)^using\s+') { throw 'Protection agent has no using directive anchor.' }
    $agentText = "using System.IO;`r`n" + $agentText
    Set-Content -Path $agent -Value $agentText -Encoding utf8
}

# Registry access is explicitly guarded at the narrow Windows-only call site so
# the application-only service boundary does not leak CA1416 to all host callers/tests.
$browserBootstrap = Join-Path $Root 'src/DKLock.Service/Protection/DefaultBrowserPolicyBootstrapper.cs'
if (-not (Test-Path $browserBootstrap)) { throw "Missing V10 default browser bootstrapper: $browserBootstrap" }
$browserText = Get-Content $browserBootstrap -Raw
$browserText = $browserText.Replace("[SupportedOSPlatform(`"windows`")]`r`ninternal sealed class DefaultBrowserPolicyBootstrapper", 'internal sealed class DefaultBrowserPolicyBootstrapper')
$browserText = $browserText.Replace("[SupportedOSPlatform(`"windows`")]`ninternal sealed class DefaultBrowserPolicyBootstrapper", 'internal sealed class DefaultBrowserPolicyBootstrapper')
$methodMarker = "    private string? ResolveOwnerLocalAppData()`r`n    {`r`n"
if (-not $browserText.Contains($methodMarker)) { $methodMarker = "    private string? ResolveOwnerLocalAppData()`n    {`n" }
if (-not $browserText.Contains('if (!OperatingSystem.IsWindows()) return null;')) {
    if (-not $browserText.Contains($methodMarker)) { throw 'ResolveOwnerLocalAppData marker not found for Windows guard.' }
    $browserText = $browserText.Replace($methodMarker, $methodMarker + "        if (!OperatingSystem.IsWindows()) return null;`r`n")
}
Set-Content -Path $browserBootstrap -Value $browserText -Encoding utf8

# Preserve the AlreadyAuthorized contract explicitly in the IPC Code as well as the
# typed response field. The desktop agent and runtime probe must never re-prompt or
# stall when the RAM-only UntilApplicationClose session is still valid.
$hostPath = Join-Path $Root 'src/DKLock.Service/DkLockServiceHost.cs'
if (-not (Test-Path $hostPath)) { throw "Missing V10 service host: $hostPath" }
$hostText = Get-Content $hostPath -Raw
$authorizedPattern = 'return IpcResponse\.Ok\(v, request\.RequestId, result\.AlreadyAuthorized \? "application already authorized" : "window challenge created",\s*_stateStore\.Current, challenge: result\.Challenge, alreadyAuthorized: result\.AlreadyAuthorized\);'
if ($hostText -notmatch 'windowResponse with \{ Code = "ALREADY_AUTHORIZED" \}') {
    if ($hostText -notmatch $authorizedPattern) { throw 'V10 window challenge response marker not found.' }
    $authorizedReplacement = @'
var windowResponse = IpcResponse.Ok(v, request.RequestId, result.AlreadyAuthorized ? "application already authorized" : "window challenge created",
            _stateStore.Current, challenge: result.Challenge, alreadyAuthorized: result.AlreadyAuthorized);
        return result.AlreadyAuthorized ? windowResponse with { Code = "ALREADY_AUTHORIZED" } : windowResponse;
'@
    $hostText = [regex]::Replace($hostText, $authorizedPattern, $authorizedReplacement, 1)
    Set-Content -Path $hostPath -Value $hostText -Encoding utf8
}

# Hydrate the production test/release assets and verify their immutable carrier hash.
$assetCarrier = Join-Path $PSScriptRoot 'v10-ci-assets.b64'
if (-not (Test-Path $assetCarrier)) { throw "Missing V10 test/release asset carrier: $assetCarrier" }
$assetArchive = Join-Path $tempRoot 'v10-ci-assets.tar.xz'
$assetB64 = (Get-Content $assetCarrier -Raw).Trim()
[IO.File]::WriteAllBytes($assetArchive, [Convert]::FromBase64String($assetB64))
$assetHash = (Get-FileHash $assetArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($assetHash -ne '72bfef81ed50ca736573b0222a8c5acfb26432f17bdc0110fea289302706370e') { throw "V10 test/release asset SHA mismatch: $assetHash" }
tar -xf $assetArchive -C $Root
if ($LASTEXITCODE -ne 0) { throw 'Failed to extract V10 test/release asset bundle.' }
Remove-Item $assetArchive -Force -ErrorAction SilentlyContinue
foreach ($required in @(
    'scripts/test-v10.ps1',
    'scripts/build-v10-release.ps1',
    'tests/validate_v10.py',
    'tests/DKLock.V10.ContractTests/DKLock.V10.ContractTests.csproj',
    'tests/DKLock.V10.ContractTests/Program.cs',
    'tools/DKLock.V10.Probe/DKLock.V10.Probe.csproj',
    'tools/DKLock.V10.Probe/Program.cs',
    'V10_SCOPE.md'
)) {
    if (-not (Test-Path (Join-Path $Root $required))) { throw "V10 required production asset missing after extraction: $required" }
}

# Repair the recovered test asset deterministically and parser-validate it before execution.
$gateScript = Join-Path $Root 'scripts/test-v10.ps1'
$gateText = Get-Content $gateScript -Raw
$badReportLine = '"- Installer SHA-256: `$hash`", '''','
$goodReportLine = '("- Installer SHA-256: " + $hash), '''','
if ($gateText.Contains($badReportLine)) { $gateText = $gateText.Replace($badReportLine, $goodReportLine) }
$badHashLine = 'Write-Host "V10_USER_INSTALLER_SHA256=$((Get-FileHash $userZip -Algorithm SHA256).Hash.ToLowerInvariant())"'
$goodHashLines = '$userZipHash = (Get-FileHash $userZip -Algorithm SHA256).Hash.ToLowerInvariant()' + "`r`n" + 'Write-Host "V10_USER_INSTALLER_SHA256=$userZipHash"'
if ($gateText.Contains($badHashLine)) { $gateText = $gateText.Replace($badHashLine, $goodHashLines) }
Set-Content -Path $gateScript -Value $gateText -Encoding utf8

$parseTokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($gateScript, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -ne 0) {
    $messages = ($parseErrors | ForEach-Object Message) -join '; '
    throw "V10 production gate PowerShell parse failure after deterministic repair: $messages"
}

Write-Host "Applied exact V10 target override SHA256=$targetHash, narrow Windows registry guard, explicit ALREADY_AUTHORIZED IPC status, production asset SHA256=$assetHash, and parser-validated test-v10.ps1"
