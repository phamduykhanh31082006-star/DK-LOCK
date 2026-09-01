using System.Collections.Concurrent;
using DKLock.Core.Contracts;
using DKLock.Core.Sessions;

namespace DKLock.Security.Sessions;

public sealed class InMemorySessionService : ISessionService
{
    private readonly ConcurrentDictionary<string, UnlockSession> _sessions = new(StringComparer.OrdinalIgnoreCase);

    public bool IsAuthorized(string executablePath, DateTimeOffset? now = null)
    {
        var path = Path.GetFullPath(executablePath);
        if (!_sessions.TryGetValue(path, out var session)) return false;
        if (session.IsActive(now ?? DateTimeOffset.UtcNow)) return true;
        _sessions.TryRemove(path, out _);
        return false;
    }

    public UnlockSession? Grant(string executablePath, UnlockScope scope, DateTimeOffset? now = null)
    {
        if (scope == UnlockScope.Once) return null;
        var created = now ?? DateTimeOffset.UtcNow;
        DateTimeOffset? expires = scope switch
        {
            UnlockScope.FiveMinutes => created.AddMinutes(5),
            UnlockScope.FifteenMinutes => created.AddMinutes(15),
            UnlockScope.UntilServiceRestart => null,
            _ => created
        };
        var path = Path.GetFullPath(executablePath);
        var session = new UnlockSession(Guid.NewGuid().ToString("N"), path, created, expires);
        _sessions[path] = session;
        return session;
    }

    public void Clear(string executablePath) => _sessions.TryRemove(Path.GetFullPath(executablePath), out _);
    public void ClearAll() => _sessions.Clear();

    public IReadOnlyList<UnlockSession> Snapshot(DateTimeOffset? now = null)
    {
        var utcNow = now ?? DateTimeOffset.UtcNow;
        foreach (var item in _sessions)
            if (!item.Value.IsActive(utcNow)) _sessions.TryRemove(item.Key, out _);
        return _sessions.Values.OrderBy(x => x.ExecutablePath, StringComparer.OrdinalIgnoreCase).ToArray();
    }
}
