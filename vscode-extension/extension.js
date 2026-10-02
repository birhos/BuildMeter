// BuildMeter — VS Code / Cursor / Antigravity eklentisi.
//
// Editörde çalıştırılan build ve çalıştırma komutlarının bekleme süresini ölçer ve
// ~/.buildmeter/events.jsonl dosyasına yazar. Dört yoldan veri toplar:
//
//   1. Debug oturumları: Flutter (dart) için flutter.appStarted olayı; .NET (coreclr) ve
//      Node (Next.js, Vite, CRA dev sunucusu) için debug çıktısındaki "hazır" satırı.
//   2. Task'lar: npm: build gibi bitişi ölçülen task'lar, çıkış koduyla.
//   3. Entegre terminal: shell integration ile terminale yazılan komutlar. Wrapper kuruluysa
//      kaydı wrapper yazar; eklenti wrapper'ın bastığı işareti görünce geri çekilir.
//   4. Kaynak bilgisi: editörün terminallerine BUILDMETER_SOURCE eklenir; wrapper ve MSBuild
//      hook'u kaydı "terminal" yerine editörün adıyla yazar.
//
// .NET build'lerini her yerde MSBuild hook'u yazar; eklenti dotnet build/publish/test
// komutlarını ve dotnet task'larını atlar.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const { Recorder, EVENTS } = require('./lib/events');
const { LineScanner, wrapperMarker, hasVisibleText } = require('./lib/scanner');
const { resolveCommandLine } = require('./lib/resolve');
const { byID, isReady, waitsForReady, records } = require('./lib/profiles');

/** Wrapper işaretini beklerken start satırını erteleme süresi. */
const MARKER_WAIT_MS = 1500;

function editorSource() {
  const name = (vscode.env.appName || '').toLowerCase();
  if (name.includes('antigravity')) return 'antigravity';
  if (name.includes('cursor')) return 'cursor';
  if (name.includes('visual studio code') || name.includes('vscode')) return 'vscode';
  return 'other';
}

const SOURCE = editorSource();

/** Kapanmamış bütün kayıtlar; pencere kapanırken iptal olarak kapatılır. */
const open = new Set();

function track(rec) {
  open.add(rec);
  return rec;
}

function finish(rec, status) {
  rec.end(status);
  open.delete(rec);
}

function statusFor(exitCode, onSuccess) {
  if (exitCode === 0) return onSuccess;
  if (exitCode === undefined || exitCode === 130 || exitCode === 137 || exitCode === 143) return 'cancelled';
  return 'failed';
}

function firstFolder() {
  const folders = vscode.workspace.workspaceFolders;
  return folders && folders.length ? folders[0].uri.fsPath : '';
}

function findUp(dir, test) {
  while (dir && dir !== path.dirname(dir)) {
    const hit = test(dir);
    if (hit) return hit;
    dir = path.dirname(dir);
  }
  return null;
}

function readJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

// MARK: - 1. Debug oturumları

/** pubspec.yaml'ı yukarı doğru arayıp proje adını ve Flutter projesi olup olmadığını döndürür. */
function readPubspec(startDir) {
  return findUp(startDir, (dir) => {
    const file = path.join(dir, 'pubspec.yaml');
    if (!fs.existsSync(file)) return null;
    try {
      const text = fs.readFileSync(file, 'utf8');
      const name = (text.match(/^name:\s*([^\s#]+)/m) || [])[1] || path.basename(dir);
      return { name, isFlutter: /^\s*sdk:\s*flutter\s*$/m.test(text) };
    } catch {
      return { name: path.basename(dir), isFlutter: false };
    }
  });
}

function sessionDir(session) {
  const cfg = session.configuration || {};
  if (cfg.cwd) return cfg.cwd;
  if (cfg.program && path.isAbsolute(cfg.program)) return path.dirname(cfg.program);
  if (session.workspaceFolder) return session.workspaceFolder.uri.fsPath;
  return firstFolder();
}

/** Flutter: oturumun başından flutter.appStarted olayına kadar. */
const dartSessions = new Map();

function onDartSessionStart(session) {
  if (session.type !== 'dart') return;
  const cfg = session.configuration || {};
  if (cfg.request === 'attach') return;
  const cwd = sessionDir(session);
  const pub = readPubspec(cwd);
  const rec = track(new Recorder({
    source: SOURCE, tech: 'flutter', tool: 'flutter', kind: 'run',
    project: (pub && pub.name) || path.basename(cwd) || session.name, device: cfg.deviceId || '',
  }));
  const state = { rec, flutter: !!(pub && pub.isFlutter) };
  dartSessions.set(session.id, state);
  // Flutter projesi olduğu belliyse hemen "derleniyor" göster.
  if (state.flutter) rec.emitStart();
}

function onDartCustomEvent(e) {
  const state = dartSessions.get(e.session.id);
  if (!state) return;
  const name = e.event || '';
  if (name === 'flutter.appStart' || name.endsWith('.appStart')) {
    state.flutter = true;
    if (e.body && e.body.deviceId) state.rec.base.device = e.body.deviceId;
    state.rec.emitStart();
  } else if ((name === 'flutter.appStarted' || name.endsWith('.appStarted')) && state.flutter) {
    finish(state.rec, 'success');
    dartSessions.delete(e.session.id);
  }
}

function onDartSessionEnd(session) {
  const state = dartSessions.get(session.id);
  if (!state) return;
  dartSessions.delete(session.id);
  // Uygulama açılmadan oturum bitti: build hatası veya kullanıcı durdurdu.
  if (state.flutter) finish(state.rec, 'cancelled');
  else { state.rec.discard(); open.delete(state.rec); }
}

/** coreclr: proje dosyasını bulur ve web/worker uygulaması olup olmadığını söyler. */
function dotnetDebugTarget(session) {
  const cfg = session.configuration || {};
  const dirs = [cfg.cwd, cfg.program && path.dirname(cfg.program), session.workspaceFolder && session.workspaceFolder.uri.fsPath]
    .filter(Boolean);
  for (const start of dirs) {
    const file = findUp(start, (dir) => {
      let entries = [];
      try { entries = fs.readdirSync(dir); } catch { return null; }
      const projects = entries.filter((f) => /\.(cs|fs|vb)proj$/i.test(f));
      return projects.length === 1 ? path.join(dir, projects[0]) : null;
    });
    if (file) {
      let hosted = true;
      try { hosted = /Microsoft\.NET\.Sdk\.(Web|Worker|BlazorWebAssembly|Razor)/.test(fs.readFileSync(file, 'utf8')); } catch { /* yoksay */ }
      return { project: path.basename(file, path.extname(file)), hosted };
    }
  }
  const program = cfg.program ? path.basename(cfg.program, path.extname(cfg.program)) : '';
  return { project: program || session.name, hosted: true };
}

/** node, pwa-node: package.json bağımlılıklarından dev sunucusu profilini seçer. */
function nodeDebugTarget(session) {
  const pkgDir = findUp(sessionDir(session), (dir) => (fs.existsSync(path.join(dir, 'package.json')) ? dir : null));
  if (!pkgDir) return null;
  const pkg = readJSON(path.join(pkgDir, 'package.json')) || {};
  const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
  let profile = null;
  let tech = '';
  if (deps.next) { profile = byID.get('next-dev'); tech = 'next'; }
  else if (deps.vite) { profile = byID.get('vite-dev'); tech = deps.react ? 'react' : 'vite'; }
  else if (deps['react-scripts']) { profile = byID.get('cra-start'); tech = 'react'; }
  return profile ? { profile, tech, project: pkg.name || path.basename(pkgDir) } : null;
}

/**
 * js-debug bir ana ve bir (ya da birkaç) alt oturum açar; hepsi aynı kökün tek kaydını paylaşır.
 * @type {Map<string, {rec: Recorder, scanner: LineScanner, endOnProcess: boolean}>}
 */
const trackedRoots = new Map();

function rootSession(session) {
  let s = session;
  while (s.parentSession) s = s.parentSession;
  return s;
}

/**
 * Debug adapter mesajlarını izleyen tracker. dart yukarıdaki özel olaylarla, node-terminal
 * entegre terminal toplayıcısıyla ölçülür; chrome/pwa-chrome oturumları kayıt yazmaz, süre
 * dev sunucusu tarafında ölçülür.
 */
function createTracker(session) {
  const cfg = session.configuration || {};
  const root = rootSession(session);
  let shared = trackedRoots.get(root.id);
  if (!shared) {
    if (cfg.request === 'attach' && !session.parentSession) return undefined;
    shared = newDebugRecord(session);
    if (!shared) return undefined;
    trackedRoots.set(root.id, shared);
  }
  const { rec, scanner, endOnProcess } = shared;
  const stop = () => {
    finish(rec, 'cancelled');
    trackedRoots.delete(root.id);
  };
  return {
    onDidSendMessage(m) {
      if (!m || m.type !== 'event' || rec.ended) return;
      if (m.event === 'output' && m.body && typeof m.body.output === 'string' && m.body.category !== 'telemetry') {
        if (endOnProcess && m.body.category === 'stdout') finish(rec, 'success');
        else scanner.write(m.body.output);
      } else if (m.event === 'process' && endOnProcess) {
        finish(rec, 'success');
      }
    },
    onWillStopSession: stop,
    onExit: stop,
    onError: stop,
  };
}

function newDebugRecord(session) {
  let rec;
  let profile;
  let endOnProcess = false;
  if (session.type === 'coreclr') {
    const target = dotnetDebugTarget(session);
    profile = byID.get('dotnet-run');
    endOnProcess = !target.hosted; // konsol uygulaması "hazır" satırı basmaz
    rec = new Recorder({ source: SOURCE, tech: 'dotnet', tool: 'coreclr', kind: 'run', project: target.project });
  } else if (session.type === 'node' || session.type === 'pwa-node') {
    const target = nodeDebugTarget(session);
    if (!target) return null;
    profile = target.profile;
    rec = new Recorder({ source: SOURCE, tech: target.tech, tool: 'node', kind: profile.kind, project: target.project });
  } else {
    return null;
  }
  track(rec).emitStart();
  const scanner = new LineScanner((line) => {
    if (!isReady(profile, line)) return false;
    finish(rec, 'success');
    return true;
  });
  return { rec, scanner, endOnProcess };
}

// MARK: - 2. Task'lar

/**
 * Task'lar kendi terminallerinde çalışır ve orada da shell execution olayı üretir. Aynı komut
 * iki toplayıcıdan da görülürse task kaydı kalır; olayların sırası belli olmadığı için
 * kontrol iki yönde yapılır.
 */
const DEDUP_MS = 3000;
const recentTasks = new Map(); // komut satırı → başlangıç zamanı
const recentShell = new Map(); // komut satırı → { at, state }
const taskRecords = new Map();

function substituteVariables(value, folder) {
  return String(value).replace(/\$\{workspaceFolder\}/g, folder).replace(/\$\{workspaceRoot\}/g, folder);
}

function taskCommand(task) {
  const folder = task.scope && task.scope.uri ? task.scope.uri.fsPath : firstFolder();
  const exec = task.execution;
  const def = task.definition || {};
  let commandLine = '';
  let cwd = folder;
  const text = (v) => (v && typeof v === 'object' && 'value' in v ? v.value : v);
  if (exec && exec.options && exec.options.cwd) cwd = path.resolve(folder, substituteVariables(exec.options.cwd, folder));
  if (exec && typeof exec.commandLine === 'string') {
    commandLine = exec.commandLine;
  } else if (exec && exec.command) {
    commandLine = [text(exec.command), ...(exec.args || []).map(text)].join(' ');
  } else if (exec && exec.process) {
    commandLine = [exec.process, ...(exec.args || [])].join(' ');
  }
  if (def.type === 'npm' && def.script) {
    if (!commandLine) commandLine = `npm run ${def.script}`;
    if (def.path) cwd = path.resolve(folder, def.path);
  }
  return { commandLine: substituteVariables(commandLine, folder), cwd };
}

function onTaskStart(e) {
  const task = e.execution.task;
  const { commandLine, cwd } = taskCommand(task);
  if (!commandLine) return;
  const r = resolveCommandLine(commandLine, cwd);
  // dotnet task'larını MSBuild hook'u yazar. Arka plan task'larının (npm: dev) hazır anı
  // task API'sinden okunamaz.
  if (!r || r.tech === 'dotnet' || waitsForReady(r.profile) || !records(r.profile)) return;
  const key = commandLine.trim();
  recentTasks.set(key, Date.now());
  const shell = recentShell.get(key);
  if (shell && Date.now() - shell.at < DEDUP_MS) dropShellRecord(shell.state);
  const rec = track(new Recorder({ source: SOURCE, tech: r.tech, tool: r.tool, kind: r.profile.kind, project: r.project, device: r.device }));
  rec.emitStart();
  taskRecords.set(e.execution, rec);
}

function onTaskEnd(e) {
  const rec = taskRecords.get(e.execution);
  if (!rec) return;
  taskRecords.delete(e.execution);
  finish(rec, statusFor(e.exitCode, 'success'));
}

// MARK: - 3. Entegre terminal

const shellRecords = new Map();

function onShellExecutionStart(e) {
  const execution = e.execution;
  const commandLine = execution.commandLine && execution.commandLine.value;
  if (!commandLine) return;
  const cwdUri = execution.cwd || (e.shellIntegration && e.shellIntegration.cwd);
  const cwd = cwdUri ? cwdUri.fsPath : firstFolder();
  const r = resolveCommandLine(commandLine, cwd);
  // dotnet build/publish/test kaydını MSBuild hook'u yazar.
  if (!r || !records(r.profile) || (r.tech === 'dotnet' && r.profile.kind === 'build')) return;
  const key = commandLine.trim();
  const taskStarted = recentTasks.get(key);
  if (taskStarted && Date.now() - taskStarted < DEDUP_MS) return;

  // Okuma hemen başlamalı: read() yalnızca çağrıldıktan sonra yazılan veriyi verir.
  const stream = execution.read();
  const rec = track(new Recorder({ source: SOURCE, tech: r.tech, tool: r.tool, kind: r.profile.kind, project: r.project, device: r.device }));
  const waitReady = waitsForReady(r.profile) && !r.dotnetConsole;
  const state = { rec, waitReady, sawOutput: false, timer: setTimeout(() => rec.emitStart(), MARKER_WAIT_MS) };
  shellRecords.set(execution, state);
  recentShell.set(key, { at: Date.now(), state });

  const scanner = new LineScanner((line) => {
    if (!isReady(r.profile, line)) return false;
    finish(rec, 'success');
    return true;
  });
  (async () => {
    let tail = '';
    for await (const data of stream) {
      if (rec.ended) break;
      // İşaret iki parçaya bölünmüş olabilir.
      const text = tail + data;
      if (wrapperMarker.test(text)) {
        // Komutu wrapper kaydediyor; aynı komut için ikinci kayıt yazılmaz.
        dropShellRecord(state);
        break;
      }
      tail = text.slice(-64);
      if (!state.sawOutput && hasVisibleText(data)) state.sawOutput = true;
      if (waitReady) scanner.write(data);
    }
  })().catch((err) => console.error('[buildmeter]', err));
}

function dropShellRecord(state) {
  clearTimeout(state.timer);
  state.rec.discard();
  open.delete(state.rec);
}

function onShellExecutionEnd(e) {
  const state = shellRecords.get(e.execution);
  if (!state) return;
  shellRecords.delete(e.execution);
  clearTimeout(state.timer);
  if (state.rec.ended) return;
  if (!state.rec.started && (!state.sawOutput || e.exitCode === 130)) {
    // Prompt'un bastığı OSC 133 dizileri (oh-my-zsh, powerlevel10k …) VS Code'a her komut
    // için ikinci, hemen 130 ile biten bir execution ürettirir; kaydedilmez. Aynı kural ilk
    // saniyelerde Ctrl+C ile kesilen komutları da kayda almaz.
    dropShellRecord(state);
    return;
  }
  finish(state.rec, statusFor(e.exitCode, state.waitReady ? 'cancelled' : 'success'));
}

// MARK: - Etkinleştirme

function activate(context) {
  // 4. Editörün terminallerine (task terminalleri dahil) kaynak bilgisi.
  const env = context.environmentVariableCollection;
  env.description = 'BuildMeter: build kayıtlarının hangi editörden geldiğini belirtir';
  env.replace('BUILDMETER_SOURCE', SOURCE);

  const subs = context.subscriptions;
  subs.push(
    vscode.debug.onDidStartDebugSession(onDartSessionStart),
    vscode.debug.onDidReceiveDebugSessionCustomEvent(onDartCustomEvent),
    vscode.debug.onDidTerminateDebugSession(onDartSessionEnd),
    vscode.debug.registerDebugAdapterTrackerFactory('*', { createDebugAdapterTracker: createTracker }),
    vscode.tasks.onDidStartTaskProcess(onTaskStart),
    vscode.tasks.onDidEndTaskProcess(onTaskEnd),
    vscode.commands.registerCommand('buildmeter.openLog', () => {
      vscode.window.showTextDocument(vscode.Uri.file(EVENTS));
    }),
  );
  // Shell execution API'leri VS Code 1.93'te stable oldu.
  if (vscode.window.onDidStartTerminalShellExecution) {
    subs.push(
      vscode.window.onDidStartTerminalShellExecution(onShellExecutionStart),
      vscode.window.onDidEndTerminalShellExecution(onShellExecutionEnd),
    );
  }
}

function deactivate() {
  // Pencere yeniden yüklenirken ya da kapanırken açık kalan oturumlar iptal sayılır.
  for (const rec of open) {
    if (rec.started) rec.end('cancelled');
  }
  open.clear();
}

module.exports = { activate, deactivate };
