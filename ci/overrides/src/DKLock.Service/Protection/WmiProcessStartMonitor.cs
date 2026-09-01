using System.Diagnostics;
using System.Management;

#pragma warning disable CA1416 // System.Management is Windows-only; calls are guarded by OperatingSystem.IsWindows().

namespace DKLock.Service.Protection;

public sealed class WmiProcessStartMonitor : IProcessStartMonitor
{
    private ManagementEventWatcher? _watcher;
    private bool _started;

    public event EventHandler<ProcessStartEvent>? ProcessStarted;

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_started) return Task.CompletedTask;
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("DK LOCK process monitoring requires Windows.");

        var query = new WqlEventQuery("SELECT * FROM Win32_ProcessStartTrace");
        _watcher = new ManagementEventWatcher(query);
        _watcher.EventArrived += OnEventArrived;
        _watcher.Start();
        _started = true;
        return Task.CompletedTask;
    }

    private void OnEventArrived(object sender, EventArrivedEventArgs e)
    {
        try
        {
            var processId = Convert.ToInt32((uint)e.NewEvent.Properties["ProcessID"].Value);
            _ = Task.Run(async () =>
            {
                var path = await ResolvePathAsync(processId);
                if (!string.IsNullOrWhiteSpace(path))
                    ProcessStarted?.Invoke(this, new ProcessStartEvent(processId, path, DateTimeOffset.UtcNow));
            });
        }
        catch { }
    }

    private static async Task<string?> ResolvePathAsync(int processId)
    {
        for (var attempt = 0; attempt < 12; attempt++)
        {
            try
            {
                using var process = Process.GetProcessById(processId);
                var path = process.MainModule?.FileName;
                if (!string.IsNullOrWhiteSpace(path)) return Path.GetFullPath(path);
            }
            catch (ArgumentException) { return null; }
            catch { }
            await Task.Delay(25).ConfigureAwait(false);
        }
        return null;
    }

    public ValueTask DisposeAsync()
    {
        if (_watcher is not null)
        {
            try { _watcher.Stop(); } catch { }
            _watcher.EventArrived -= OnEventArrived;
            _watcher.Dispose();
            _watcher = null;
        }
        _started = false;
        return ValueTask.CompletedTask;
    }
}

#pragma warning restore CA1416
