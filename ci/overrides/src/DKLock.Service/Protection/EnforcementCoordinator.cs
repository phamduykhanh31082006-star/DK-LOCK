using DKLock.Core.Authentication;
using DKLock.Core.Contracts;
using DKLock.Core.Protection;
using DKLock.Core.Sessions;
using DKLock.Security.Policies;
using DKLock.Security.Protection;
using DKLock.Security.Sessions;

namespace DKLock.Service.Protection;

public sealed class EnforcementCoordinator : IChallengeService, IAsyncDisposable
{
    private readonly IProcessStartMonitor _monitor;
    private readonly IProcessEnforcer _enforcer;
    private readonly ApplicationPolicyCache _policies;
    private readonly IAuthenticationService _authentication;
    private readonly InMemorySessionService _sessions;
    private readonly ChallengeRegistry _challenges;
    private readonly IActivityService _activity;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TimeSpan _challengeLifetime;

    public EnforcementCoordinator(
        IProcessStartMonitor monitor,
        IProcessEnforcer enforcer,
        ApplicationPolicyCache policies,
        IAuthenticationService authentication,
        InMemorySessionService sessions,
        ChallengeRegistry challenges,
        IActivityService activity,
        TimeSpan? challengeLifetime = null)
    {
        _monitor = monitor;
        _enforcer = enforcer;
        _policies = policies;
        _authentication = authentication;
        _sessions = sessions;
        _challenges = challenges;
        _activity = activity;
        _challengeLifetime = challengeLifetime ?? TimeSpan.FromSeconds(30);
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _policies.RefreshAsync(cancellationToken);
        _monitor.ProcessStarted += OnProcessStarted;
        await _monitor.StartAsync(cancellationToken);
    }

    private void OnProcessStarted(object? sender, ProcessStartEvent e) => _ = HandleProcessStartedAsync(e, _lifetime.Token);

    private async Task HandleProcessStartedAsync(ProcessStartEvent e, CancellationToken cancellationToken)
    {
        try
        {
            if (!_policies.TryGetEnabled(e.ExecutablePath, out var policy) || policy is null) return;
            if (_sessions.IsAuthorized(policy.ExecutablePath))
            {
                await _activity.AppendAsync("APP_ALLOWED_SESSION", $"Allowed {policy.DisplayName} using an active application session.", cancellationToken);
                return;
            }

            if (!_enforcer.TrySuspend(e.ProcessId, out var suspendError))
            {
                await _activity.AppendAsync("APP_SUSPEND_FAILED", $"Could not suspend {policy.DisplayName}: {suspendError}", cancellationToken);
                return;
            }

            var challenge = _challenges.Add(e.ProcessId, policy.ExecutablePath, policy.DisplayName, _challengeLifetime);
            await _activity.AppendAsync("APP_SUSPENDED", $"Suspended {policy.DisplayName} and created unlock challenge {challenge.ChallengeId[..8]}.", cancellationToken);
            _ = ExpireAsync(challenge, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception ex)
        {
            await _activity.AppendAsync("APP_ENFORCEMENT_ERROR", $"Application enforcement error: {ex.Message}", CancellationToken.None);
        }
    }

    private async Task ExpireAsync(ProtectionChallenge challenge, CancellationToken cancellationToken)
    {
        try
        {
            var delay = challenge.ExpiresUtc - DateTimeOffset.UtcNow;
            if (delay > TimeSpan.Zero) await Task.Delay(delay, cancellationToken);
            if (!_challenges.TryGet(challenge.ChallengeId, out var current) || current is null) return;
            if (_enforcer.IsAlive(current.ProcessId)) _enforcer.TryTerminate(current.ProcessId, out _);
            _challenges.Resolve(current.ChallengeId);
            await _activity.AppendAsync("APP_CHALLENGE_TIMEOUT", $"Closed {current.DisplayName} after the unlock challenge expired.", CancellationToken.None);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    public async Task<ChallengeResolution> ResolveAsync(string challengeId, string secret, CredentialKind credentialKind, UnlockScope unlockScope, CancellationToken cancellationToken = default)
    {
        if (!_challenges.TryGet(challengeId, out var challenge) || challenge is null)
            return new(challengeId, false, "CHALLENGE_NOT_FOUND", "The unlock request is no longer active.", unlockScope);

        if (challenge.ExpiresUtc <= DateTimeOffset.UtcNow)
        {
            if (_enforcer.IsAlive(challenge.ProcessId)) _enforcer.TryTerminate(challenge.ProcessId, out _);
            _challenges.Resolve(challengeId);
            return new(challengeId, false, "CHALLENGE_EXPIRED", "The unlock request expired.", unlockScope);
        }

        var auth = await _authentication.VerifyAsync(secret, credentialKind, cancellationToken);
        if (!auth.Succeeded)
        {
            _challenges.RecordFailure(challengeId);
            await _activity.AppendAsync("AUTH_FAILED", $"Authentication failed for {challenge.DisplayName}. Code={auth.Code}", cancellationToken);
            return new(challengeId, false, auth.Code, auth.Message ?? "Authentication failed.", unlockScope);
        }

        if (!_enforcer.TryResume(challenge.ProcessId, out var resumeError))
        {
            _challenges.Resolve(challengeId);
            await _activity.AppendAsync("APP_RESUME_FAILED", $"Could not resume {challenge.DisplayName}: {resumeError}", cancellationToken);
            return new(challengeId, false, "RESUME_FAILED", "Authentication succeeded, but the application could not be resumed.", unlockScope);
        }

        if (unlockScope != UnlockScope.Once) _sessions.Grant(challenge.ExecutablePath, unlockScope);
        _challenges.Resolve(challengeId);
        await _activity.AppendAsync("APP_UNLOCKED", $"Unlocked {challenge.DisplayName} using {credentialKind} with scope {unlockScope}.", cancellationToken);
        return new(challengeId, true, "OK", "Application unlocked.", unlockScope);
    }

    public void ClearSessions() => _sessions.ClearAll();

    public async ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        _monitor.ProcessStarted -= OnProcessStarted;
        await _monitor.DisposeAsync();
        _lifetime.Dispose();
    }
}
