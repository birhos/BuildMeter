namespace BuildMeter.Core;

/// <summary>
/// Ham oturumları gösterilecek oturumlara dönüştürür (macOS'taki SessionMerger ile aynı):
/// <list type="bullet">
/// <item>Aynı <c>group</c> id'li kayıtlar tek oturumdur.</item>
/// <item>Grupsuz MSBuild kayıtları aynı kaynak, makine ve çözüm için aralarında
/// <see cref="MSBuildGap"/>'ten az boşluk varsa tek oturumda birleşir.</item>
/// <item>Başarısız MSBuild build'inde <c>end</c> gelmez. Açık kalan MSBuild oturumu aynı kaynaktan
/// yeni bir build başlayınca ya da son etkinlikten <see cref="MSBuildOpenLimit"/> sonra
/// <c>failed</c> olur; bitişi bilinen son etkinlik anıdır.</item>
/// </list>
/// </summary>
public static class SessionMerger
{
    public const double MSBuildGap = 2;
    public const double MSBuildOpenLimit = 15 * 60;

    public static List<Session> Merge(IEnumerable<Session> raw, double now)
    {
        var result = new List<Session>();
        var groups = new Dictionary<string, List<Session>>();
        var msbuild = new Dictionary<string, List<Session>>();
        var groupOrder = new List<string>();
        var msbuildOrder = new List<string>();

        foreach (var s in raw.OrderBy(s => s.Start).ThenBy(s => s.Id, StringComparer.Ordinal))
        {
            if (s.Group.Length > 0)
            {
                if (!groups.ContainsKey(s.Group)) { groups[s.Group] = []; groupOrder.Add(s.Group); }
                groups[s.Group].Add(s);
            }
            else if (s.IsMSBuild)
            {
                var key = $"{s.Source}|{s.Host}|{s.Solution}";
                if (!msbuild.ContainsKey(key)) { msbuild[key] = []; msbuildOrder.Add(key); }
                msbuild[key].Add(s);
            }
            else
            {
                result.Add(s);
            }
        }

        foreach (var g in groupOrder) result.Add(Combine(groups[g], "group:" + g, now, closesOpen: false));

        foreach (var key in msbuildOrder)
        {
            var cluster = new List<Session>();
            double activityEnd = 0;
            foreach (var s in msbuild[key])
            {
                if (cluster.Count > 0 && s.Start > activityEnd + MSBuildGap)
                {
                    result.Add(Combine(cluster, cluster[0].Id, now, closesOpen: true));
                    cluster = [];
                    activityEnd = 0;
                }
                cluster.Add(s);
                activityEnd = Math.Max(activityEnd, s.EndOr(s.Start));
            }
            if (cluster.Count > 0) result.Add(Combine(cluster, cluster[0].Id, now, closesOpen: false));
        }
        return result;
    }

    static Session Combine(List<Session> members, string id, double now, bool closesOpen)
    {
        if (members.Count == 1 && !closesOpen && !(members[0].IsMSBuild && members[0].IsActive)) return members[0];

        // Wrapper'ın kaydı varsa o asıl kayıttır; yoksa en son biten MSBuild kaydı.
        var primary = members.FirstOrDefault(m => !m.IsMSBuild)
            ?? members.Aggregate((a, b) => b.EndOr(b.Start) > a.EndOr(a.Start) ? b : a);

        var merged = primary.Clone();
        merged.Id = id;
        merged.Start = members.Min(m => m.Start);
        merged.End = null;
        merged.Status = "running";
        merged.Pid = 0;
        if (merged.Device.Length == 0)
        {
            // Wrapper cihaz bilmez; MSBuild kaydının hedef çatısı ve konfigürasyonu kullanılır.
            var device = members.LastOrDefault(m => m.Device.Length > 0)?.Device;
            if (device is not null) merged.Device = device;
        }

        if (!primary.IsMSBuild)
        {
            merged.End = primary.End;
            merged.Status = primary.Status;
            merged.Pid = primary.Pid;
            return merged;
        }

        double activityEnd = members.Max(m => m.EndOr(m.Start));
        bool hasOpen = members.Any(m => m.IsActive);
        if (hasOpen && !closesOpen && now - activityEnd < MSBuildOpenLimit) return merged;

        merged.End = activityEnd;
        merged.Status = hasOpen || members.Any(m => m.Status == "failed") ? "failed"
            : members.Any(m => m.Status == "cancelled") ? "cancelled"
            : "success";
        return merged;
    }
}
