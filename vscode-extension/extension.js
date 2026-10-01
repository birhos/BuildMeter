// BuildMeter — VS Code / Cursor eklentisi.
//
// "Start Debugging" (F5) ile başlatılan Flutter oturumlarında, oturumun başladığı
// andan Flutter'ın `flutter.appStarted` olayını gönderdiği ana (uygulama cihazda
// açıldı) kadar geçen süreyi ölçer ve ~/.buildmeter/events.jsonl'e yazar.

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = process.env.BUILDMETER_DATA_DIR || path.join(os.homedir(), '.buildmeter');
const EVENTS = path.join(DATA_DIR, 'events.jsonl');

/** @type {Map<string, {id: string, start: number, project: string, device: string, flutter: boolean, started: boolean, cwd: string}>} */
const pending = new Map();

function editorSource() {
  const name = (vscode.env.appName || '').toLowerCase();
  if (name.includes('cursor')) return 'cursor';
  if (name.includes('visual studio code') || name.includes('vscode')) return 'vscode';
  return 'other';
}

function write(event) {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.appendFileSync(EVENTS, JSON.stringify(event) + '\n');
  } catch (err) {
    console.error('[buildmeter]', err);
  }
}

/** pubspec.yaml'ı yukarı doğru arayıp proje adını ve Flutter projesi olup olmadığını döndürür. */
function readPubspec(startDir) {
  let dir = startDir;
  while (dir && dir !== path.dirname(dir)) {
    const file = path.join(dir, 'pubspec.yaml');
    if (fs.existsSync(file)) {
      try {
        const text = fs.readFileSync(file, 'utf8');
        const name = (text.match(/^name:\s*([^\s#]+)/m) || [])[1] || path.basename(dir);
        const isFlutter = /^\s*sdk:\s*flutter\s*$/m.test(text);
        return { name, isFlutter };
      } catch {
        return { name: path.basename(dir), isFlutter: false };
      }
    }
    dir = path.dirname(dir);
  }
  return null;
}

function sessionDir(session) {
  const cfg = session.configuration || {};
  if (cfg.cwd) return cfg.cwd;
  if (cfg.program && path.isAbsolute(cfg.program)) return path.dirname(cfg.program);
  if (session.workspaceFolder) return session.workspaceFolder.uri.fsPath;
  const folders = vscode.workspace.workspaceFolders;
  return folders && folders.length ? folders[0].uri.fsPath : '';
}

function common(p) {
  return {
    id: p.id,
    source: editorSource(),
    kind: 'run',
    project: p.project,
    device: p.device,
  };
}

function emitStart(p) {
  if (p.started) return;
  p.started = true;
  write({ event: 'start', ...common(p), ts: p.start, pid: process.pid });
}

function emitEnd(p, status) {
  emitStart(p);
  write({ event: 'end', ...common(p), start: p.start, ts: Date.now() / 1000, status });
}

function activate(context) {
  context.subscriptions.push(
    vscode.debug.onDidStartDebugSession((session) => {
      if (session.type !== 'dart') return;
      const cfg = session.configuration || {};
      if (cfg.request === 'attach') return;

      const cwd = sessionDir(session);
      const pub = readPubspec(cwd);
      const p = {
        id: crypto.randomUUID(),
        start: Date.now() / 1000,
        project: (pub && pub.name) || path.basename(cwd) || session.name,
        device: cfg.deviceId || '',
        flutter: !!(pub && pub.isFlutter),
        started: false,
        cwd,
      };
      pending.set(session.id, p);
      // Flutter projesi olduğu belliyse hemen "derleniyor" göster.
      if (p.flutter) emitStart(p);
    }),

    vscode.debug.onDidReceiveDebugSessionCustomEvent((e) => {
      const p = pending.get(e.session.id);
      if (!p) return;
      const name = e.event || '';
      if (name === 'flutter.appStart' || name.endsWith('.appStart')) {
        p.flutter = true;
        if (e.body && e.body.deviceId) p.device = e.body.deviceId;
        emitStart(p);
      } else if (name === 'flutter.appStarted' || name.endsWith('.appStarted')) {
        if (!p.flutter) return;
        emitEnd(p, 'success');
        pending.delete(e.session.id);
      }
    }),

    vscode.debug.onDidTerminateDebugSession((session) => {
      const p = pending.get(session.id);
      if (!p) return;
      pending.delete(session.id);
      // Uygulama açılmadan oturum bitti: build hatası veya kullanıcı durdurdu.
      if (p.flutter) emitEnd(p, 'cancelled');
    }),

    vscode.commands.registerCommand('buildmeter.openLog', () => {
      vscode.window.showTextDocument(vscode.Uri.file(EVENTS));
    }),
  );
}

function deactivate() {
  for (const p of pending.values()) {
    if (p.flutter) emitEnd(p, 'cancelled');
  }
  pending.clear();
}

module.exports = { activate, deactivate };
