namespace BuildMeter.Core;

/// <summary>Kaynak, teknoloji ve durum değerlerinin görünen adları.</summary>
public static class Titles
{
    public static readonly string[] KnownSources = ["terminal", "vscode", "cursor", "antigravity", "rider", "visualstudio"];
    public static readonly string[] KnownTechs = ["flutter", "dotnet", "react", "next", "vite"];

    static readonly Dictionary<string, string> Techs = new()
    {
        ["flutter"] = "Flutter", ["dotnet"] = ".NET", ["react"] = "React", ["next"] = "Next.js", ["vite"] = "Vite",
        ["other"] = "Diğer",
    };

    static readonly Dictionary<string, string> Sources = new()
    {
        ["terminal"] = "Terminal", ["vscode"] = "VS Code", ["cursor"] = "Cursor", ["antigravity"] = "Antigravity",
        ["rider"] = "Rider", ["visualstudio"] = "Visual Studio", ["other"] = "Diğer",
    };

    static readonly Dictionary<string, string> Statuses = new()
    {
        ["running"] = "Devam ediyor", ["success"] = "Başarılı", ["failed"] = "Başarısız",
        ["cancelled"] = "İptal / tamamlanmadı",
    };

    public static string Tech(string key) => Techs.GetValueOrDefault(key, Techs["other"]);
    public static string Source(string key) => Sources.GetValueOrDefault(key, Sources["other"]);
    public static string Status(string key) => Statuses.GetValueOrDefault(key, Statuses["failed"]);
}
