using System;
using System.Runtime.InteropServices;
using System.Threading;
using EnvDTE80;
using Microsoft.VisualStudio;
using Microsoft.VisualStudio.Shell;
using Microsoft.VisualStudio.Shell.Interop;
using Task = System.Threading.Tasks.Task;

namespace BuildMeter.VisualStudio;

/// <summary>
/// Visual Studio build'lerini solution düzeyinde tek kayıt olarak, F5 ile başlatılan .NET
/// uygulamalarını da "çalıştır → hazır" kaydı olarak <c>~/.buildmeter/events.jsonl</c>'a yazar.
/// </summary>
/// <remarks>
/// Yüklendiğinde <c>BUILDMETER_VSIX</c> ortam değişkenini ayarlar; MSBuild hook'u bunu görünce
/// Visual Studio içindeki proje build'leri için kayıt yazmaz, böylece aynı build iki kez sayılmaz.
/// </remarks>
[PackageRegistration(UseManagedResourcesOnly = true, AllowsBackgroundLoading = true)]
[Guid(PackageGuid)]
[ProvideAutoLoad(VSConstants.UICONTEXT.SolutionExists_string, PackageAutoLoadFlags.BackgroundLoad)]
public sealed class BuildMeterPackage : AsyncPackage
{
    public const string PackageGuid = "0f6c9d4e-3b7a-4e21-9c58-7a1d2e4b6f83";

    SolutionBuildTracker? _builds;
    DebugRunTracker? _runs;

    protected override async Task InitializeAsync(CancellationToken cancellationToken, IProgress<ServiceProgressData> progress)
    {
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("BUILDMETER_DISABLE"))) return;

        await JoinableTaskFactory.SwitchToMainThreadAsync(cancellationToken);
        var buildManager = await GetServiceAsync(typeof(SVsSolutionBuildManager)) as IVsSolutionBuildManager2;
        var solution = await GetServiceAsync(typeof(SVsSolution)) as IVsSolution;
        var debugger = await GetServiceAsync(typeof(SVsShellDebugger)) as IVsDebugger;
        var dte = await GetServiceAsync(typeof(EnvDTE.DTE)) as DTE2;
        if (buildManager is null || solution is null || debugger is null || dte is null) return;

        // Hook bu değişkeni hedef çalışırken okur; ayarlandıktan sonraki build'leri VSIX yazar.
        Environment.SetEnvironmentVariable("BUILDMETER_VSIX", "1");
        _runs = new DebugRunTracker(debugger, dte);
        _builds = new SolutionBuildTracker(buildManager, solution, _runs);
    }

    /// <summary>Kabuk paketi ana iş parçacığında kapatır.</summary>
    protected override void Dispose(bool disposing)
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        if (disposing)
        {
            _builds?.Dispose();
            _runs?.Dispose();
        }
        base.Dispose(disposing);
    }
}
