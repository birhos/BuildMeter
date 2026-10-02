using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using BuildMeter.Core;
using Microsoft.Win32;

namespace BuildMeter.Tray;

/// <summary>
/// Tepsi uygulaması. Toplayıcıların yazdığı olay dosyalarını saniyede bir okur; macOS menü bar
/// uygulamasıyla aynı özeti açılır pencerede ve tepsi simgesinin ipucunda gösterir.
/// </summary>
public partial class App : Application
{
    const string InstanceName = @"Local\BuildMeter.Tray";
    const string ShowEventName = @"Local\BuildMeter.Tray.Show";

    Mutex? _instance;
    EventWaitHandle? _showEvent;
    EventStore _store = null!;
    MainViewModel _model = null!;
    MainWindow _window = null!;
    TrayIcon _tray = null!;
    DispatcherTimer _timer = null!;
    int _ticks;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Tek kopya: ikinci açılış ilk kopyanın penceresini gösterip çıkar.
        _instance = new Mutex(true, InstanceName, out bool first);
        if (!first)
        {
            if (EventWaitHandle.TryOpenExisting(ShowEventName, out var existing)) existing.Set();
            Shutdown();
            return;
        }
        base.OnStartup(e);

        Theme.Apply(Resources);
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        Autostart.RefreshPath();

        _store = new EventStore();
        _store.Refresh(Stats.Now());
        _model = new MainViewModel(_store);
        _window = new MainWindow(_model, this);
        _tray = new TrayIcon(this);
        _tray.Update(_store.Sessions, Stats.Now());

        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        ThreadPool.RegisterWaitForSingleObject(_showEvent, (_, _) => Dispatcher.BeginInvoke(ShowWindow), null, Timeout.Infinite, false);

        _timer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Tick(), Dispatcher);
        _timer.Start();

        if (!e.Args.Contains(Autostart.BackgroundArgument)) ShowWindow();
    }

    void Tick()
    {
        _ticks++;
        double now = Stats.Now();
        bool hadActive = _store.Active.Any();
        // Aktif build varken saniyede bir, yoksa yeni satır geldiğinde ya da 30 sn'de bir hesapla.
        bool changed = _store.Refresh(now, force: hadActive || _ticks % 30 == 0);
        if (_ticks % 10 == 0) _store.ExpireDeadSessions(now);
        if (changed || hadActive || _ticks % 30 == 0)
        {
            _tray.Update(_store.Sessions, now);
            if (_window.IsVisible) _model.Update(now);
        }
    }

    public void ShowWindow()
    {
        _model.Update(Stats.Now());
        _window.ShowNearTray();
    }

    public void ToggleWindow()
    {
        // Tepsiye tıklamak önce pencerenin odağını kaybettirip kapatır; aynı tık yeniden açmasın.
        if (_window.IsVisible || DateTime.UtcNow - _window.HiddenAt < TimeSpan.FromMilliseconds(300))
            _window.Hide();
        else
            ShowWindow();
    }

    public void OpenDataFolder() => Open(_store.DataDirectory);

    public void ReloadAll()
    {
        double now = Stats.Now();
        _store.ReloadAll(now);
        _tray.Update(_store.Sessions, now);
        _model.Update(now);
    }

    public void Quit()
    {
        _timer.Stop();
        _tray.Dispose();
        Shutdown();
    }

    public static void Open(string target, string? arguments = null)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { Arguments = arguments ?? "", UseShellExecute = true });
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            MessageBox.Show(e.Message, "BuildMeter", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category == UserPreferenceCategory.General) Dispatcher.BeginInvoke(() => Theme.Apply(Resources));
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _showEvent?.Dispose();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
