using System;
using System.IO;
using Microsoft.VisualStudio;
using Microsoft.VisualStudio.Shell;
using Microsoft.VisualStudio.Shell.Interop;

namespace BuildMeter.VisualStudio;

/// <summary>
/// Build Solution, Rebuild Solution ve F5 öncesi build'i solution düzeyinde tek kayıt olarak yazar.
/// Yalnızca temizleme (Clean Solution) kayıt yazmaz.
/// </summary>
sealed class SolutionBuildTracker : IVsUpdateSolutionEvents2, IVsUpdateSolutionEvents4, IDisposable
{
    readonly IVsSolutionBuildManager2 _buildManager;
    readonly IVsSolution _solution;
    readonly DebugRunTracker _runs;
    readonly uint _cookie;
    readonly uint _cookie4;

    Recorder? _build;
    double _begin;

    public SolutionBuildTracker(IVsSolutionBuildManager2 buildManager, IVsSolution solution, DebugRunTracker runs)
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        _buildManager = buildManager;
        _solution = solution;
        _runs = runs;
        buildManager.AdviseUpdateSolutionEvents(this, out _cookie);
        if (buildManager is IVsSolutionBuildManager5 manager5) manager5.AdviseUpdateSolutionEvents4(this, out _cookie4);
    }

    public int UpdateSolution_Begin(ref int pfCancelUpdate)
    {
        _begin = EventWriter.Now();
        _build = null;
        return VSConstants.S_OK;
    }

    /// <summary>Build adımı başlayınca kayıt açılır; başlangıç solution build'inin başıdır (Rebuild'de temizlik dahil).</summary>
    public void UpdateSolution_BeginUpdateAction(uint dwAction)
    {
        if (_build is not null || (dwAction & (uint)VSSOLNBUILDUPDATEFLAGS.SBF_OPERATION_BUILD) == 0) return;
        ThreadHelper.ThrowIfNotOnUIThread();
        _build = new Recorder("build", SolutionName(), _runs.PendingGroup, _begin);
        _build.Start();
    }

    public int UpdateSolution_Done(int fSucceeded, int fModified, int fCancelCommand)
    {
        Finish(fCancelCommand != 0 ? "cancelled" : fSucceeded != 0 ? "success" : "failed");
        return VSConstants.S_OK;
    }

    public int UpdateSolution_Cancel()
    {
        Finish("cancelled");
        return VSConstants.S_OK;
    }

    void Finish(string status)
    {
        var build = _build;
        _build = null;
        if (build is null) return;
        build.End(status);
        _runs.BuildFinished(status);
    }

    string SolutionName()
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        _solution.GetSolutionInfo(out _, out var file, out _);
        return string.IsNullOrEmpty(file) ? "?" : Path.GetFileNameWithoutExtension(file);
    }

    public int UpdateSolution_StartUpdate(ref int pfCancelUpdate) => VSConstants.S_OK;
    public int OnActiveProjectCfgChange(IVsHierarchy pIVsHierarchy) => VSConstants.S_OK;
    public int UpdateProjectCfg_Begin(IVsHierarchy pHierProj, IVsCfg pCfgProj, IVsCfg pCfgSln, uint dwAction, ref int pfCancel) => VSConstants.S_OK;
    public int UpdateProjectCfg_Done(IVsHierarchy pHierProj, IVsCfg pCfgProj, IVsCfg pCfgSln, uint dwAction, int fSuccess, int fCancel) => VSConstants.S_OK;
    public void UpdateSolution_QueryDelayFirstUpdateAction(out int pfDelay) => pfDelay = 0;
    public void UpdateSolution_BeginFirstUpdateAction() { }
    public void UpdateSolution_EndLastUpdateAction() { }
    public void UpdateSolution_EndUpdateAction(uint dwAction) { }
    public void OnActiveProjectCfgChangeBatchBegin() { }
    public void OnActiveProjectCfgChangeBatchEnd() { }

    public void Dispose()
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        _build?.End("cancelled");
        _buildManager.UnadviseUpdateSolutionEvents(_cookie);
        if (_cookie4 != 0 && _buildManager is IVsSolutionBuildManager5 manager5) manager5.UnadviseUpdateSolutionEvents4(_cookie4);
    }
}
