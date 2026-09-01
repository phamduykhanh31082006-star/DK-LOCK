using System.IO;
using System.Collections.ObjectModel;
using System.Windows.Input;
using DKLock.App.Dialogs;
using DKLock.App.Mvvm;
using DKLock.App.Services;
using DKLock.App.ViewModels.Items;

namespace DKLock.App.ViewModels;

public sealed class ApplicationsViewModel : PageViewModel
{
    private readonly ServiceConnectionCoordinator _connection;
    private readonly IAppDialogService _dialogs;
    private string _statusMessage = "Loading application policies…";
    private bool _busy;

    public ApplicationsViewModel(ServiceConnectionCoordinator connection, IAppDialogService dialogs)
        : base("applications", "Applications", "Protect selected Windows applications with DK LOCK.")
    {
        _connection = connection;
        _dialogs = dialogs;
        AddCommand = new AsyncRelayCommand(AddAsync, () => !Busy);
        RefreshCommand = new AsyncRelayCommand(RefreshAsync, () => !Busy);
        ToggleCommand = new AsyncRelayCommand<ApplicationPolicyItemViewModel>(ToggleAsync, item => item is not null && !Busy);
        RemoveCommand = new AsyncRelayCommand<ApplicationPolicyItemViewModel>(RemoveAsync, item => item is not null && !Busy);
        _ = RefreshAsync();
    }

    public ObservableCollection<ApplicationPolicyItemViewModel> Applications { get; } = new();
    public ICommand AddCommand { get; }
    public ICommand RefreshCommand { get; }
    public ICommand ToggleCommand { get; }
    public ICommand RemoveCommand { get; }

    public bool Busy { get => _busy; private set => SetProperty(ref _busy, value); }
    public string StatusMessage { get => _statusMessage; private set => SetProperty(ref _statusMessage, value); }
    public bool HasApplications => Applications.Count > 0;

    public async Task RefreshAsync()
    {
        Busy = true;
        try
        {
            var response = await _connection.GetApplicationsAsync();
            if (!response.Success) { StatusMessage = response.Message; return; }
            Replace(response.Items);
            StatusMessage = Applications.Count == 0 ? "No protected applications yet." : $"{Applications.Count} application policy(s).";
        }
        finally { Busy = false; }
    }

    private async Task AddAsync()
    {
        var path = await _dialogs.PickExecutableAsync();
        if (string.IsNullOrWhiteSpace(path)) return;

        var setup = await _connection.GetSecuritySetupAsync();
        if (setup is null) { _dialogs.ShowMessage("DK LOCK", "The protection service is offline."); return; }
        if (!setup.MasterPasswordConfigured)
        {
            var password = await _dialogs.SetupMasterPasswordAsync();
            if (string.IsNullOrEmpty(password)) return;
            var configured = await _connection.SetupMasterPasswordAsync(password);
            password = string.Empty;
            if (!configured.Success) { _dialogs.ShowMessage("Master password", configured.Message); return; }
        }

        Busy = true;
        try
        {
            var response = await _connection.AddApplicationAsync(path, Path.GetFileNameWithoutExtension(path), enabled: true);
            if (!response.Success) { _dialogs.ShowMessage("Unable to protect application", response.Message); return; }
            Replace(response.Items);
            StatusMessage = $"Protection enabled for {Path.GetFileNameWithoutExtension(path)}.";
        }
        finally { Busy = false; }
    }

    private async Task ToggleAsync(ApplicationPolicyItemViewModel? item)
    {
        if (item is null) return;
        var desired = !item.Enabled;
        if (desired)
        {
            var setup = await _connection.GetSecuritySetupAsync();
            if (setup is null) { _dialogs.ShowMessage("DK LOCK", "The protection service is offline."); return; }
            if (!setup.MasterPasswordConfigured)
            {
                var password = await _dialogs.SetupMasterPasswordAsync();
                if (string.IsNullOrEmpty(password)) return;
                var configured = await _connection.SetupMasterPasswordAsync(password);
                password = string.Empty;
                if (!configured.Success) { _dialogs.ShowMessage("Master password", configured.Message); return; }
            }
        }

        Busy = true;
        try
        {
            var response = await _connection.SetApplicationEnabledAsync(item.Id, desired);
            if (!response.Success) { _dialogs.ShowMessage("Protection change failed", response.Message); return; }
            Replace(response.Items);
        }
        finally { Busy = false; }
    }

    private async Task RemoveAsync(ApplicationPolicyItemViewModel? item)
    {
        if (item is null) return;
        Busy = true;
        try
        {
            var response = await _connection.RemoveApplicationAsync(item.Id);
            if (!response.Success) { _dialogs.ShowMessage("Remove failed", response.Message); return; }
            Replace(response.Items);
            StatusMessage = $"Removed {item.DisplayName}.";
        }
        finally { Busy = false; }
    }

    private void Replace(IReadOnlyList<DKLock.Core.Applications.ApplicationPolicy> items)
    {
        Applications.Clear();
        foreach (var item in items) Applications.Add(new ApplicationPolicyItemViewModel(item));
        OnPropertyChanged(nameof(HasApplications));
    }
}
