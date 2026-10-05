#!/bin/bash
# BuildMeter'ı kaldırır. Kayıtlı veriler (~/.buildmeter/events.jsonl)
# silinmez; silmek için --purge verin.
set -uo pipefail

pkill -x BuildMeter 2>/dev/null
rm -rf /Applications/BuildMeter.app
echo "✓ Uygulama kaldırıldı"

for entry in "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code|$HOME/Library/Application Support/Code" \
             "/Applications/Cursor.app/Contents/Resources/app/bin/cursor|$HOME/Library/Application Support/Cursor" \
             "/Applications/Antigravity IDE.app/Contents/Resources/app/bin/antigravity-ide|$HOME/Library/Application Support/Antigravity IDE" \
             "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity|$HOME/Library/Application Support/Antigravity"; do
  IFS='|' read -r cli support <<<"$entry"
  [ -x "$cli" ] || continue
  "$cli" --uninstall-extension HaydarDemir.buildmeter >/dev/null 2>&1
  storage="$support/User/globalStorage/storage.json"
  [ -f "$storage" ] && node -e 'for (const p of JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).userDataProfiles||[]) console.log(p.name)' "$storage" 2>/dev/null |
    while IFS= read -r profile; do
      "$cli" --uninstall-extension HaydarDemir.buildmeter --profile "$profile" >/dev/null 2>&1
    done
done
echo "✓ Editör eklentileri kaldırıldı"

sed -i '' '/# BuildMeter/d;/buildmeter\.zsh/d' "$HOME/.zshrc" 2>/dev/null
sed -i '' '/# BuildMeter/d;/buildmeter\.sh/d' "$HOME/.bashrc" 2>/dev/null
rm -rf "$HOME/.buildmeter/bin" "$HOME/.buildmeter/buildmeter.zsh" "$HOME/.buildmeter/buildmeter.sh"
echo "✓ Terminal wrapper'ı kaldırıldı (yeni terminal açın)"

rm -f "$HOME/Library/Application Support/Microsoft/MSBuild/Current/Microsoft.Common.targets/ImportAfter/BuildMeter.targets" \
      "$HOME/.local/share/Microsoft/MSBuild/Current/Microsoft.Common.targets/ImportAfter/BuildMeter.targets"
echo "✓ MSBuild hook'u kaldırıldı"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.buildmeter"
  echo "✓ Kayıtlı veriler silindi"
fi
