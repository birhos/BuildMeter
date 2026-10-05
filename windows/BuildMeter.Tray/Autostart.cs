using Microsoft.Win32;

namespace BuildMeter.Tray;

/// <summary>Oturum açılınca başlatma: <c>HKCU\...\Run</c> altındaki <c>BuildMeter</c> değeri.</summary>
static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "BuildMeter";

    /// <summary>Girişte başlatılırken pencere açılmaz, yalnızca tepsi simgesi gelir.</summary>
    public const string BackgroundArgument = "--background";

    static string Command => $"\"{Environment.ProcessPath}\" {BackgroundArgument}";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string value && value.Length > 0;
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(ValueName, Command);
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    /// <summary>Uygulama taşındıysa kayıtlı yolu günceller.</summary>
    public static void RefreshPath()
    {
        if (IsEnabled) Set(true);
    }
}
