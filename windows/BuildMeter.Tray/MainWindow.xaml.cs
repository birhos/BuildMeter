using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using BuildMeter.Core;
using Microsoft.Win32;

namespace BuildMeter.Tray;

/// <summary>Tepsi simgesine tıklanınca görev çubuğunun yanında açılan pencere.</summary>
public partial class MainWindow : Window
{
    readonly MainViewModel _model;
    readonly App _app;
    bool _dialogOpen;

    public MainWindow(MainViewModel model, App app)
    {
        InitializeComponent();
        _model = model;
        _app = app;
        DataContext = model;
        Deactivated += (_, _) =>
        {
            if (_dialogOpen) return;
            HiddenAt = DateTime.UtcNow;
            Hide();
        };
        SizeChanged += (_, _) => PlaceNearTray();
        KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape) Hide();
        };
    }

    /// <summary>Pencere odağı kaybedip kapandığı an; tepsi tıklamasıyla hemen yeniden açılmasını önler.</summary>
    public DateTime HiddenAt { get; private set; }

    public void ShowNearTray()
    {
        MaxHeight = SystemParameters.WorkArea.Height;
        Scroller.ScrollToTop();
        Show();
        PlaceNearTray();
        Activate();
    }

    /// <summary>Pencereyi görev çubuğunun bulunduğu köşeye yerleştirir (varsayılan: sağ alt). Kenar boşluğu gölgenin payıdır.</summary>
    void PlaceNearTray()
    {
        var area = SystemParameters.WorkArea;
        bool taskbarTop = area.Top > 0, taskbarLeft = area.Left > 0;
        Left = taskbarLeft ? area.Left : area.Right - ActualWidth;
        Top = taskbarTop ? area.Top : area.Bottom - ActualHeight;
    }

    void Settings_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = SettingsButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        var autostart = new MenuItem { Header = "Girişte başlat", IsCheckable = true, IsChecked = Autostart.IsEnabled };
        autostart.Click += (_, _) => Autostart.Set(autostart.IsChecked);
        menu.Items.Add(autostart);
        menu.Items.Add(Item("Veri klasörünü aç", _app.OpenDataFolder));
        menu.Items.Add(Item("Verileri yeniden yükle", _app.ReloadAll));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Çıkış", _app.Quit));
        menu.IsOpen = true;
    }

    static MenuItem Item(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }

    void CopyReport_Click(object sender, RoutedEventArgs e)
    {
        var text = ReportBuilder.Text(_model.FilteredSessions, _model.SelectedRange.Range, _model.FilterKey, DateTime.Now);
        if (!TrySetClipboard(text)) return;
        CopyGlyph.Text = "";
        CopyLabel.Text = "Kopyalandı";
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            CopyGlyph.Text = "";
            CopyLabel.Text = "Raporu kopyala";
        };
        timer.Start();
    }

    /// <summary>Pano başka bir uygulamada açıkken kısa süre meşgul olabilir; birkaç kez denenir.</summary>
    static bool TrySetClipboard(string text)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetText(text);
                return true;
            }
            catch (COMException)
            {
                Thread.Sleep(50);
            }
        }
        return false;
    }

    void ExportCsv_Click(object sender, RoutedEventArgs e)
    {
        var range = _model.SelectedRange.Range;
        var now = DateTime.Now;
        var dialog = new SaveFileDialog
        {
            FileName = ReportBuilder.CsvFileName(range, _model.FilterKey, now),
            Filter = "CSV dosyası (*.csv)|*.csv",
            DefaultExt = ".csv",
            AddExtension = true,
        };
        _dialogOpen = true;
        bool? ok;
        try { ok = dialog.ShowDialog(this); }
        finally { _dialogOpen = false; }
        if (ok != true) return;

        try
        {
            // Metin zaten BOM ile başlar; ikinci bir BOM yazılmaz.
            File.WriteAllText(dialog.FileName, ReportBuilder.Csv(_model.FilteredSessions, range, now), new UTF8Encoding(false));
            App.Open("explorer.exe", $"/select,\"{dialog.FileName}\"");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _dialogOpen = true;
            MessageBox.Show(this, ex.Message, "CSV kaydedilemedi", MessageBoxButton.OK, MessageBoxImage.Warning);
            _dialogOpen = false;
        }
    }
}
