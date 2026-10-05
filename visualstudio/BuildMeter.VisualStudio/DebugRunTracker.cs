using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using EnvDTE;
using EnvDTE80;
using Microsoft.VisualStudio;
using Microsoft.VisualStudio.Debugger.Interop;
using Microsoft.VisualStudio.Shell;
using Microsoft.VisualStudio.Shell.Interop;

namespace BuildMeter.VisualStudio;

/// <summary>
/// F5 (Debug.Start) ile başlatılan uygulamanın "çalıştır → hazır" süresini kaydeder.
/// <list type="bullet">
/// <item>Başlangıç: F5'e basıldığı an. Ardından gelen build aynı <c>group</c> ile yazılır ve bu
/// kayıtla tek oturumda birleşir.</item>
/// <item>Bitiş: web, worker ve Blazor projelerinde debug çıktısındaki hazır satırı
/// (<c>Now listening on:</c>; ASP.NET Core bunu Debug günlüğüne de yazar); konsol uygulamalarında
/// debugger'ın çalışma kipine geçmesi.</item>
/// <item>Build başarısız olursa <c>failed</c>, hazır olmadan durdurulursa <c>cancelled</c>.</item>
/// </list>
/// </summary>
sealed class DebugRunTracker : IVsDebuggerEvents, IDebugEventCallback2, IDisposable
{
    readonly IVsDebugger _debugger;
    readonly DTE2 _dte;
    readonly uint _cookie;
    // Olay nesnesi referansı tutulmazsa çöp toplayıcı aboneliği düşürür.
    readonly CommandEvents _startCommand;
    readonly Regex[] _signals = ReadySignals.For("dotnet-run");
    readonly object _gate = new();

    Recorder? _run;
    LineScanner? _scanner;
    string? _group;
    bool _hosted;
    bool _launched;

    public DebugRunTracker(IVsDebugger debugger, DTE2 dte)
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        _debugger = debugger;
        _dte = dte;
        debugger.AdviseDebuggerEvents(this, out _cookie);
        debugger.AdviseDebugEventCallback(this);
        _startCommand = dte.Events.CommandEvents[
            VSConstants.GUID_VSStandardCommandSet97.ToString("B"), (int)VSConstants.VSStd97CmdID.Start];
        _startCommand.BeforeExecute += OnDebugStart;
    }

    /// <summary>F5 sonrası build'in bu kayda bağlanması için grup id'si; uygulama başladıysa yok.</summary>
    public string? PendingGroup
    {
        get
        {
            lock (_gate) return _run is { Ended: false } && !_launched ? _group : null;
        }
    }

    void OnDebugStart(string guid, int id, object customIn, object customOut, ref bool cancelDefault)
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        // Durdurulmuş bir oturumda Start, "Continue" demektir.
        var mode = new DBGMODE[1];
        if (_debugger.GetMode(mode) != VSConstants.S_OK || mode[0] != DBGMODE.DBGMODE_Design) return;
        if (StartupProject() is not { } project) return;

        lock (_gate)
        {
            _run?.End("cancelled");
            _group = Guid.NewGuid().ToString("N");
            _hosted = DotnetProject.IsHosted(project.FullName);
            _launched = false;
            _scanner = new LineScanner(line => _signals.Any(r => r.IsMatch(line)));
            _run = new Recorder("run", project.Name, _group);
            _run.Start();
        }
    }

    /// <summary>F5'in tetiklediği build bitti; başarısızsa uygulama başlamayacak.</summary>
    public void BuildFinished(string status)
    {
        lock (_gate)
        {
            if (_run is { Ended: false } && !_launched && status != "success") _run.End(status);
        }
    }

    public int OnModeChange(DBGMODE dbgmodeNew)
    {
        lock (_gate)
        {
            if (_run is not { Ended: false }) return VSConstants.S_OK;
            if (dbgmodeNew == DBGMODE.DBGMODE_Run && !_launched)
            {
                _launched = true;
                if (!_hosted) _run.End("success");
            }
            else if (dbgmodeNew == DBGMODE.DBGMODE_Design)
            {
                _run.End("cancelled");
            }
        }
        return VSConstants.S_OK;
    }

    public int Event(IDebugEngine2 pEngine, IDebugProcess2 pProcess, IDebugProgram2 pProgram, IDebugThread2 pThread,
        IDebugEvent2 pEvent, ref Guid riidEvent, uint dwAttrib)
    {
        try
        {
            if (riidEvent == typeof(IDebugOutputStringEvent2).GUID && pEvent is IDebugOutputStringEvent2 output &&
                output.GetString(out var text) == VSConstants.S_OK)
            {
                lock (_gate)
                {
                    if (_run is { Ended: false } && _hosted && _scanner is not null)
                    {
                        _scanner.Write(text);
                        if (_scanner.Done) _run.End("success");
                    }
                }
            }
        }
        finally
        {
            Release(pEngine);
            Release(pProcess);
            Release(pProgram);
            Release(pThread);
            Release(pEvent);
        }
        return VSConstants.S_OK;
    }

    static void Release(object? o)
    {
        if (o is not null && Marshal.IsComObject(o)) Marshal.ReleaseComObject(o);
    }

    /// <summary>İlk başlangıç projesi (çoklu başlangıçta ilki).</summary>
    Project? StartupProject()
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        try
        {
            if (_dte.Solution?.SolutionBuild?.StartupProjects is not object[] { Length: > 0 } names) return null;
            return _dte.Solution.Item(names[0]);
        }
        catch (Exception e) when (e is COMException or ArgumentException)
        {
            return null;
        }
    }

    public void Dispose()
    {
        ThreadHelper.ThrowIfNotOnUIThread();
        lock (_gate) _run?.End("cancelled");
        _startCommand.BeforeExecute -= OnDebugStart;
        _debugger.UnadviseDebugEventCallback(this);
        _debugger.UnadviseDebuggerEvents(_cookie);
    }
}
