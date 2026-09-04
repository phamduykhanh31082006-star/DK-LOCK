param(
    [Parameter(Mandatory=$true)][string]$Root
)

$overlay = Join-Path $Root 'src/DKLock.App/Protection/ApplicationLockOverlayWindow.xaml'
$xaml = Get-Content $overlay -Raw
$xaml = $xaml.Replace('<Grid Background="{DynamicResource Brush.Window}">', '<Grid>')
Set-Content -Path $overlay -Value $xaml -Encoding utf8NoBOM -NoNewline

$hostPath = Join-Path $Root 'src/DKLock.Service/DkLockServiceHost.cs'
$host = Get-Content $hostPath -Raw
$old = @'
    private async Task<ProtectionHealthSnapshot> BuildProtectionHealthAsync(CancellationToken cancellationToken)
    {
        var state = _stateStore.Current;
        var applications = _policies.Snapshot();
        var settings = _smartProtection.Settings;
        return new ProtectionHealthSnapshot(
            CoreOnline: state.ProtectionHealth != ProtectionHealth.Offline,
            ApplicationProtectionAvailable: state.ProtectionHealth != ProtectionHealth.Offline,
            EnabledApplicationPolicies: applications.Count(p => p.Enabled),
            FolderProtectionAvailable: false,
            EnabledFolderPolicies: 0,
            LockedFolderPolicies: 0,
            SecureDocumentsAvailable: false,
            AccountVaultAvailable: false,
            SmartProtectionEnabled: settings.Enabled,
            IdleTimeoutMinutes: settings.IdleTimeoutMinutes,
            LockOnWorkstationLock: settings.LockOnWorkstationLock,
            LockOnSuspend: settings.LockOnSuspend,
            LockEpoch: _smartProtection.Epoch,
            LastLockReason: _smartProtection.LastTransition?.Reason ?? state.LastLockReason,
            LastGlobalLockUtc: _smartProtection.LastTransition?.OccurredUtc ?? state.LastGlobalLockUtc,
            Summary: state.StatusMessage);
    }
'@
$new = @'
    private Task<ProtectionHealthSnapshot> BuildProtectionHealthAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = _stateStore.Current;
        var applications = _policies.Snapshot();
        var settings = _smartProtection.Settings;
        return Task.FromResult(new ProtectionHealthSnapshot(
            CoreOnline: state.ProtectionHealth != ProtectionHealth.Offline,
            ApplicationProtectionAvailable: state.ProtectionHealth != ProtectionHealth.Offline,
            EnabledApplicationPolicies: applications.Count(p => p.Enabled),
            FolderProtectionAvailable: false,
            EnabledFolderPolicies: 0,
            LockedFolderPolicies: 0,
            SecureDocumentsAvailable: false,
            AccountVaultAvailable: false,
            SmartProtectionEnabled: settings.Enabled,
            IdleTimeoutMinutes: settings.IdleTimeoutMinutes,
            LockOnWorkstationLock: settings.LockOnWorkstationLock,
            LockOnSuspend: settings.LockOnSuspend,
            LockEpoch: _smartProtection.Epoch,
            LastLockReason: _smartProtection.LastTransition?.Reason ?? state.LastLockReason,
            LastGlobalLockUtc: _smartProtection.LastTransition?.OccurredUtc ?? state.LastGlobalLockUtc,
            Summary: state.StatusMessage));
    }
'@
if (-not $host.Contains($old)) { throw 'Expected V10 protection-health method was not found.' }
$host = $host.Replace($old, $new)
Set-Content -Path $hostPath -Value $host -Encoding utf8NoBOM -NoNewline

Write-Host 'Applied deterministic V10 compile fixes: overlay Grid background and warning-free protection health task.'
