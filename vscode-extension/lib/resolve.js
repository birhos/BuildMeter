// Bir komut satırını profile çözer. wrapper/resolve.go ile aynı kuralları uygular; eklenti
// wrapper kurulu olmadan da çalışabilmek için mantığın kendi kopyasını taşır.

const fs = require('fs');
const path = require('path');
const { matchProfile, firstPositional } = require('./profiles');

/**
 * @typedef {{profile: object, tech: string, tool: string, project: string, device: string, dotnetConsole?: boolean}} Resolved
 */

/** "/usr/bin/npm" → "npm", "npm.cmd" → "npm" */
function commandName(p) {
  let base = path.basename(String(p).replace(/\\/g, '/')).toLowerCase();
  for (const ext of ['.exe', '.cmd', '.bat', '.ps1']) if (base.endsWith(ext)) base = base.slice(0, -ext.length);
  return base;
}

/** n'inci konumsal argümandan sonrasını döndürür. */
function afterPositional(args, n) {
  let seen = 0;
  for (let i = 0; i < args.length; i++) {
    if (!args[i].startsWith('-') && ++seen === n) return args.slice(i + 1);
  }
  return [];
}

function flagValue(args, ...names) {
  for (let i = 0; i < args.length; i++) {
    for (const n of names) {
      if (args[i] === n && i + 1 < args.length) return args[i + 1];
      if (args[i].startsWith(n + '=')) return args[i].slice(n.length + 1);
    }
  }
  return '';
}

function findUp(dir, name) {
  for (;;) {
    if (fs.existsSync(path.join(dir, name))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}

/**
 * Komut satırını çözer; hiçbir profile uymayan komutlar için null döner.
 * @param {string[]} argv
 * @param {string} cwd
 * @returns {Resolved | null}
 */
function resolve(argv, cwd) {
  if (!argv.length) return null;
  const name = commandName(argv[0]);
  const args = argv.slice(1);
  switch (name) {
    case 'flutter':
      return resolveFlutter('flutter', args, cwd);
    case 'fvm': {
      const sub = firstPositional(args);
      if (sub === 'flutter') return resolveFlutter('fvm', afterPositional(args, 1), cwd);
      if (sub === 'spawn') return resolveFlutter('fvm', afterPositional(args, 2), cwd);
      return null;
    }
    case 'dotnet':
      return resolveDotnet(args, cwd);
    case 'npm': case 'pnpm': case 'yarn': case 'bun':
      return resolvePackageManager(name, args, cwd);
    case 'npx': case 'bunx':
      return resolveJSTool(name, stripRunnerFlags(args), cwd);
    case 'next': case 'vite': case 'react-scripts':
      return resolveJSTool(name, argv, cwd);
  }
  return null;
}

// MARK: - Flutter

function resolveFlutter(tool, args, cwd) {
  const p = matchProfile('flutter', args);
  if (!p) return null;
  const device = p.kind === 'build' ? firstPositional(afterPositional(args, 1)) : flagValue(args, '-d', '--device-id');
  return { profile: p, tech: p.tech, tool, project: flutterProject(cwd), device };
}

function flutterProject(cwd) {
  const dir = findUp(cwd, 'pubspec.yaml');
  if (!dir) return path.basename(cwd);
  try {
    const m = fs.readFileSync(path.join(dir, 'pubspec.yaml'), 'utf8').match(/^name:\s*([^\s#]+)/m);
    if (m) return m[1];
  } catch { /* yoksay */ }
  return path.basename(dir);
}

// MARK: - .NET

const dotnetExts = ['.sln', '.slnx', '.csproj', '.fsproj', '.vbproj'];

function resolveDotnet(args, cwd) {
  const p = matchProfile('dotnet', args);
  if (!p) return null;
  let rest = afterPositional(args, 1);
  if (p.id === 'dotnet-watch' && firstPositional(rest) === 'run') rest = afterPositional(rest, 1);
  let target = flagValue(rest, '--project');
  if (!target && p.id !== 'dotnet-run' && p.id !== 'dotnet-watch') target = dotnetTargetArg(rest, cwd);
  const file = dotnetProjectFile(cwd, target);
  const r = { profile: p, tech: p.tech, tool: 'dotnet', project: path.basename(cwd), device: '' };
  if (file) r.project = path.basename(file, path.extname(file));
  if (p.id === 'dotnet-run') r.dotnetConsole = !isDotnetHostedApp(file);
  return r;
}

function dotnetTargetArg(args, cwd) {
  for (const a of args) {
    if (a.startsWith('-')) continue;
    if (dotnetExts.some((ext) => a.toLowerCase().endsWith(ext))) return a;
    if (isDir(path.resolve(cwd, a))) return a;
  }
  return '';
}

function dotnetProjectFile(cwd, target) {
  let dir = cwd;
  if (target) {
    const full = path.resolve(cwd, target);
    if (isFile(full)) return full;
    dir = full;
  }
  let entries = [];
  try { entries = fs.readdirSync(dir); } catch { return ''; }
  for (const ext of dotnetExts) {
    const matches = entries.filter((e) => e.toLowerCase().endsWith(ext));
    if (matches.length === 1) return path.join(dir, matches[0]);
  }
  return '';
}

/** Web, worker ve Blazor projeleri "hazır" satırı basar; konsol uygulamaları basmaz. */
function isDotnetHostedApp(file) {
  if (!file || !file.toLowerCase().endsWith('proj')) return true;
  try {
    const s = fs.readFileSync(file, 'utf8');
    return /Microsoft\.NET\.Sdk\.(Web|Worker|BlazorWebAssembly|Razor)/.test(s);
  } catch {
    return true;
  }
}

// MARK: - JavaScript

function readPackage(dir) {
  const found = findUp(dir, 'package.json');
  if (!found) return { pkg: {}, dir };
  try {
    return { pkg: JSON.parse(fs.readFileSync(path.join(found, 'package.json'), 'utf8')), dir: found };
  } catch {
    return { pkg: {}, dir: found };
  }
}

function hasDep(pkg, name) {
  return !!((pkg.dependencies && pkg.dependencies[name]) || (pkg.devDependencies && pkg.devDependencies[name]));
}

function resolvePackageManager(pm, rawArgs, cwd) {
  const { args, dir } = stripWorkspaceFlags(pm, rawArgs, cwd);
  const sub = firstPositional(args);
  let script = '';
  if (sub === 'run' || sub === 'run-script') script = firstPositional(afterPositional(args, 1));
  else if (pm === 'npm' && sub === 'start') script = 'start';
  else if (sub === 'exec' || sub === 'x' || (pm !== 'npm' && sub === 'dlx')) {
    return resolveJSTool(pm, stripRunnerFlags(afterPositional(args, 1)), dir);
  } else if (pm !== 'npm') script = sub;
  if (!script) return null;
  const { pkg, dir: pkgDir } = readPackage(dir);
  const body = pkg.scripts && pkg.scripts[script];
  if (typeof body !== 'string') return null;
  const r = resolveScript(body, pkgDir, 0);
  if (r) r.tool = pm;
  return r;
}

/** npm -w apps/web, npm --workspace=apps/web, --prefix, pnpm -C/--dir, yarn/bun --cwd */
function stripWorkspaceFlags(pm, args, cwd) {
  const flags = new Set(['--prefix']);
  if (pm === 'npm') { flags.add('-w'); flags.add('--workspace'); }
  if (pm === 'pnpm') { flags.add('-C'); flags.add('--dir'); }
  if (pm === 'yarn' || pm === 'bun') flags.add('--cwd');
  let dir = cwd;
  const out = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const eq = a.indexOf('=');
    const name = eq >= 0 ? a.slice(0, eq) : a;
    if (!flags.has(name)) { out.push(a); continue; }
    let value = eq >= 0 ? a.slice(eq + 1) : args[++i];
    if (value === undefined) break;
    const candidate = path.resolve(cwd, value);
    if (isDir(candidate)) dir = candidate;
  }
  return { args: out, dir };
}

function stripRunnerFlags(args) {
  for (let i = 0; i < args.length; i++) {
    if (!args[i].startsWith('-')) return args.slice(i);
    if (args[i] === '-p' || args[i] === '--package') i++;
  }
  return [];
}

const envAssignment = /^[A-Za-z_][A-Za-z0-9_]*=/;

/** "tsc -b && vite build" → vite build; başka script'i çağıran script'ler izlenir. */
function resolveScript(body, pkgDir, depth) {
  if (depth > 3) return null;
  for (let tokens of splitScript(body)) {
    while (tokens.length && (envAssignment.test(tokens[0]) || tokens[0] === 'cross-env' || tokens[0] === 'env')) tokens = tokens.slice(1);
    if (!tokens.length) continue;
    const name = commandName(tokens[0]);
    if (name === 'next' || name === 'vite' || name === 'react-scripts') return resolveJSTool(name, tokens, pkgDir);
    if (name === 'npx' || name === 'bunx') {
      const r = resolveJSTool(name, stripRunnerFlags(tokens.slice(1)), pkgDir);
      if (r) return r;
    }
    if (['npm', 'pnpm', 'yarn', 'bun'].includes(name)) {
      const { args, dir } = stripWorkspaceFlags(name, tokens.slice(1), pkgDir);
      const sub = firstPositional(args);
      const script = sub === 'run' || sub === 'run-script' ? firstPositional(afterPositional(args, 1)) : sub;
      const nested = readPackage(dir);
      const inner = nested.pkg.scripts && nested.pkg.scripts[script];
      if (typeof inner === 'string') {
        const r = resolveScript(inner, nested.dir, depth + 1);
        if (r) return r;
      }
    }
  }
  return null;
}

/** Bir shell komutunu &&, ||, ; ve | ile ayrılmış parçalara, parçaları da sözcüklere böler. */
function splitScript(s) {
  const segments = [];
  let tokens = [];
  let cur = '';
  let quote = '';
  const flushToken = () => { if (cur) { tokens.push(cur); cur = ''; } };
  const flushSegment = () => { flushToken(); if (tokens.length) { segments.push(tokens); tokens = []; } };
  const chars = Array.from(s);
  for (let i = 0; i < chars.length; i++) {
    const c = chars[i];
    if (quote) {
      if (c === quote) quote = ''; else cur += c;
    } else if (c === '"' || c === "'") quote = c;
    else if (c === ' ' || c === '\t' || c === '\n') flushToken();
    else if (c === ';') flushSegment();
    else if (c === '&' || c === '|') {
      if (chars[i + 1] === c) i++;
      flushSegment();
    } else cur += c;
  }
  flushSegment();
  return segments;
}

function resolveJSTool(tool, tokens, dir) {
  if (!tokens.length) return null;
  const p = matchProfile(commandName(tokens[0]), tokens.slice(1));
  if (!p) return null;
  const { pkg, dir: pkgDir } = readPackage(dir);
  // Next.js projeleri react'ı da içerir; next önceliklidir. Vite + React → react.
  const tech = p.tech === 'vite' && hasDep(pkg, 'react') ? 'react' : p.tech;
  return { profile: p, tech, tool: commandName(tool), project: pkg.name || path.basename(pkgDir), device: '' };
}

/** Bir terminal komut satırını argv'ye çevirir; birden çok komut varsa ilk tanınanı seçer. */
function resolveCommandLine(commandLine, cwd) {
  for (let tokens of splitScript(commandLine)) {
    while (tokens.length && envAssignment.test(tokens[0])) tokens = tokens.slice(1);
    const r = tokens.length ? resolve(tokens, cwd) : null;
    if (r) return r;
  }
  return null;
}

module.exports = { resolve, resolveCommandLine, splitScript, commandName };
