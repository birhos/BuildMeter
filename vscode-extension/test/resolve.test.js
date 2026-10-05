// Wrapper ile aynı vakaları doğrular: spec/resolve-cases.json (komut çözümleme) ve
// spec/fixtures/output/ (araçların gerçek çıktılarında hazır sinyali).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { resolve, resolveCommandLine, splitScript } = require('../lib/resolve');
const { byID, isReady } = require('../lib/profiles');
const { LineScanner, wrapperMarker } = require('../lib/scanner');

const spec = path.join(__dirname, '..', '..', 'spec');

test('spec/resolve-cases.json', () => {
  const cases = JSON.parse(fs.readFileSync(path.join(spec, 'resolve-cases.json'), 'utf8'));
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'buildmeter-'));
  for (const [name, content] of Object.entries(cases.files)) {
    const file = path.join(root, ...name.split('/'));
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  }
  for (const c of cases.cases) {
    const r = resolve(c.cmd.split(/\s+/), path.join(root, ...c.cwd.split('/')));
    const got = r ? [r.profile.id, r.tech, r.tool, r.project, r.device].join(' ') : '-';
    assert.strictEqual(got, c.want, `${c.name}: ${c.cmd}`);
    if (c.dotnetConsole !== undefined) assert.strictEqual(!!r.dotnetConsole, c.dotnetConsole, `${c.name}: dotnetConsole`);
  }
  fs.rmSync(root, { recursive: true, force: true });
});

test('terminal komut satırı: ortam değişkeni ve zincir', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'buildmeter-'));
  fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ name: 'web', scripts: { dev: 'next dev' }, dependencies: { next: '15' } }));
  assert.strictEqual(resolveCommandLine('NODE_ENV=development npm run dev', root).profile.id, 'next-dev');
  assert.strictEqual(resolveCommandLine('cd . && npm run dev', root).profile.id, 'next-dev');
  assert.strictEqual(resolveCommandLine('npm install', root), null);
  fs.rmSync(root, { recursive: true, force: true });
});

test('splitScript tırnakları ve operatörleri ayırır', () => {
  assert.deepStrictEqual(splitScript(`tsc -b && vite build --mode "staging prod"; echo 'a|b' | cat`), [
    ['tsc', '-b'], ['vite', 'build', '--mode', 'staging prod'], ['echo', 'a|b'], ['cat'],
  ]);
});

test('spec/fixtures/output: gerçek çıktılarda hazır sinyali', () => {
  const root = path.join(spec, 'fixtures', 'output');
  for (const dir of fs.readdirSync(root)) {
    const profile = byID.get(dir);
    assert.ok(profile, `${dir}: böyle bir profil yok`);
    for (const file of fs.readdirSync(path.join(root, dir))) {
      const data = fs.readFileSync(path.join(root, dir, file), 'utf8');
      let ready = false;
      const scanner = new LineScanner((line) => (ready = isReady(profile, line)));
      // Gerçek akıştaki gibi küçük parçalar halinde ver.
      for (let i = 0; i < data.length; i += 7) scanner.write(data.slice(i, i + 7));
      assert.ok(ready, `${dir}/${file}: hazır sinyali bulunamadı`);
    }
  }
});

test('wrapper işareti', () => {
  assert.ok(wrapperMarker.test('önce\x1b]7799;buildmeter;0a1b2c3d\x07sonra'));
  assert.ok(!wrapperMarker.test('\x1b]633;E;npm run dev\x07'));
});

test('görünür çıktı: yalnızca kontrol dizileri sayılmaz', () => {
  const { hasVisibleText } = require('../lib/scanner');
  assert.ok(!hasVisibleText('\x1b]133;C;\x07'));
  assert.ok(!hasVisibleText('\x1b]7;file://host/path\x1b\\\x1b]133;C;\x07\r\n'));
  assert.ok(hasVisibleText('\x1b]633;C\x07> react-vite@0.0.0 build\r\n'));
});
