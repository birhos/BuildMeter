using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace BuildMeter.Tray;

/// <summary>Windows'un açık/koyu uygulama temasını izler ve renk kaynaklarını günceller.</summary>
static class Theme
{
    const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public static bool IsDark
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
                return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
            }
            catch (System.Security.SecurityException)
            {
                return false;
            }
        }
    }

    public static void Apply(ResourceDictionary resources)
    {
        bool dark = IsDark;
        Set(resources, "WindowBackground", dark ? "#202020" : "#F9F9F9");
        Set(resources, "WindowBorder", dark ? "#3A3A3A" : "#E0E0E0");
        Set(resources, "Foreground", dark ? "#FFFFFF" : "#1B1B1B");
        Set(resources, "SecondaryForeground", dark ? "#A8A8A8" : "#5F5F5F");
        Set(resources, "ChipBackground", dark ? "#2D2D2D" : "#EDEDED");
        Set(resources, "HoverBackground", dark ? "#333333" : "#E5E5E5");
        Set(resources, "Accent", dark ? "#4CA0F0" : "#0F6CBD");
        Set(resources, "AccentMuted", dark ? "#2F5E8C" : "#9CC3E8");
        Set(resources, "AccentFaint", dark ? "#1F3247" : "#E1EDF8");
        Set(resources, "ActiveBackground", dark ? "#3A2A14" : "#FFF1DE");
        Set(resources, "ActiveForeground", dark ? "#FFB45C" : "#C25E00");
        Set(resources, "Success", dark ? "#6CCB5F" : "#0F7B0F");
        Set(resources, "Failure", dark ? "#FF99A4" : "#C42B1C");
    }

    static void Set(ResourceDictionary resources, string key, string color)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
        brush.Freeze();
        resources[key] = brush;
    }
}
