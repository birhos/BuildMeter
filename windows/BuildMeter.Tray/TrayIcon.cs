using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using BuildMeter.Core;

namespace BuildMeter.Tray;

/// <summary>
/// Bildirim alanındaki simge. Sol tık pencereyi açar/kapatır, sağ tık menüyü gösterir.
/// Build sürerken simgeye turuncu bir nokta eklenir ve ipucu canlı süreyi gösterir.
/// </summary>
sealed class TrayIcon : IDisposable
{
    // NotifyIcon.Text en fazla 127 karakter alır; eski Windows sürümlerinde 63.
    const int MaxTipLength = 63;

    readonly NotifyIcon _icon;
    readonly Icon _idle;
    readonly Icon _busy;
    readonly IntPtr _busyHandle;
    bool _isBusy;

    public TrayIcon(App app)
    {
        using var stream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/BuildMeter.ico")).Stream;
        _idle = new Icon(stream, SystemInformation.SmallIconSize);
        (_busy, _busyHandle) = WithBadge(_idle);

        var menu = new ContextMenuStrip();
        menu.Items.Add("BuildMeter'ı aç", null, (_, _) => app.ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        var autostart = new ToolStripMenuItem("Girişte başlat") { CheckOnClick = true };
        autostart.Click += (_, _) => Autostart.Set(autostart.Checked);
        menu.Items.Add(autostart);
        menu.Items.Add("Veri klasörünü aç", null, (_, _) => app.OpenDataFolder());
        menu.Items.Add("Verileri yeniden yükle", null, (_, _) => app.ReloadAll());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Çıkış", null, (_, _) => app.Quit());
        menu.Opening += (_, _) => autostart.Checked = Autostart.IsEnabled;

        _icon = new NotifyIcon { Icon = _idle, Text = "BuildMeter", ContextMenuStrip = menu, Visible = true };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) app.ToggleWindow();
        };
    }

    public void Update(IReadOnlyList<Session> sessions, double now)
    {
        var active = sessions.Where(s => s.IsActive).ToList();
        string tip;
        if (active.Count > 0)
        {
            var longest = active.MinBy(s => s.Start)!;
            tip = $"{longest.Project} derleniyor · {DurationFormat.Clock(longest.Duration(now))}";
            if (active.Count > 1) tip += $" (+{active.Count - 1})";
        }
        else
        {
            var today = Stats.Summarize(sessions, ReportRange.Today, Stats.FromUnix(now));
            tip = $"Bugün {DurationFormat.Long(today.MergedTotal)} · {today.Count} build";
        }
        tip = "BuildMeter · " + tip;
        _icon.Text = tip.Length > MaxTipLength ? tip[..(MaxTipLength - 1)] + "…" : tip;

        bool busy = active.Count > 0;
        if (busy != _isBusy)
        {
            _isBusy = busy;
            _icon.Icon = busy ? _busy : _idle;
        }
    }

    /// <summary>Simgenin sağ alt köşesine turuncu bir nokta ekler.</summary>
    static (Icon, IntPtr) WithBadge(Icon source)
    {
        using var bitmap = source.ToBitmap();
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float d = bitmap.Width * 0.45f, x = bitmap.Width - d, y = bitmap.Height - d;
            using var ring = new SolidBrush(Color.White);
            using var dot = new SolidBrush(Color.FromArgb(0xF7, 0x8C, 0x1F));
            g.FillEllipse(ring, x - 1, y - 1, d + 1, d + 1);
            g.FillEllipse(dot, x, y, d - 1, d - 1);
        }
        var handle = bitmap.GetHicon();
        return (Icon.FromHandle(handle), handle);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _idle.Dispose();
        _busy.Dispose();
        DestroyIcon(_busyHandle);
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);
}
