// Komut → profil → hazır sinyali tablosu. Kaynak wrapper/profiles.json'dır; paketleme
// sırasında (vscode:prepublish) eklentinin içine kopyalanır. Eşleştirme kuralları
// wrapper/profiles.go ile aynıdır.

const fs = require('fs');
const path = require('path');

function loadProfilesJSON() {
  for (const file of [path.join(__dirname, '..', 'profiles.json'), path.join(__dirname, '..', '..', 'wrapper', 'profiles.json')]) {
    if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, 'utf8'));
  }
  throw new Error('profiles.json bulunamadı');
}

const profiles = loadProfilesJSON().profiles.map((p) => ({
  ...p,
  readyPatterns: (p.ready || []).map((expr) => new RegExp(expr, 'u')),
}));

const byID = new Map(profiles.map((p) => [p.id, p]));

/** Wrapper'ın kendi kaydını yazıp yazmayacağı (record: false → yalnızca BUILDMETER_GROUP). */
function records(profile) {
  return profile.record !== false;
}

function waitsForReady(profile) {
  return profile.readyPatterns.length > 0;
}

function isReady(profile, line) {
  return profile.readyPatterns.some((re) => re.test(line));
}

function firstPositional(args) {
  for (const a of args) {
    if (a === '--') return '';
    if (!a.startsWith('-')) return a;
  }
  return '';
}

const untracked = { vite: ['preview', 'optimize'] };

function isKnownSubcommand(tool, sub) {
  for (const p of profiles) {
    for (const [t, s] of p.commands) if (t === tool && s === sub) return true;
  }
  return (untracked[tool] || []).includes(sub);
}

/** Araç ve argümanlarına uyan profili döndürür; önce tam eşleşme, sonra "*" jokeri. */
function matchProfile(tool, args) {
  const sub = firstPositional(args);
  let wildcard = null;
  for (const p of profiles) {
    for (const [t, s] of p.commands) {
      if (t !== tool) continue;
      if (s === sub) return p;
      if (s === '*' && sub !== '' && !wildcard) wildcard = p;
    }
  }
  return wildcard && !isKnownSubcommand(tool, sub) ? wildcard : null;
}

module.exports = { profiles, byID, records, waitsForReady, isReady, matchProfile, firstPositional };
