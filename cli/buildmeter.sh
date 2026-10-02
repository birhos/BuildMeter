# BuildMeter — zsh ve bash entegrasyonu.
#   ~/.zshrc:  source ~/.buildmeter/buildmeter.zsh
#   ~/.bashrc: source ~/.buildmeter/buildmeter.sh   (Git Bash dahil)
#
# Build komutlarını süre ölçen `buildmeter track` üzerinden çağırır. Hangi alt komutun
# ölçüleceğine wrapper karar verir; diğerleri (npm install, dotnet test …) olduğu gibi
# çalışır. Geçici olarak kapatmak için: export BUILDMETER_DISABLE=1

BUILDMETER_BIN="${BUILDMETER_BIN:-$HOME/.buildmeter/bin/buildmeter}"
if [ ! -x "$BUILDMETER_BIN" ] && [ -x "$BUILDMETER_BIN.exe" ]; then
  BUILDMETER_BIN="$BUILDMETER_BIN.exe" # Git Bash
elif [ ! -x "$BUILDMETER_BIN" ] && command -v buildmeter >/dev/null 2>&1; then
  BUILDMETER_BIN="$(command -v buildmeter)"
fi

_buildmeter_track() {
  if [ -z "${BUILDMETER_DISABLE:-}" ] && [ -x "$BUILDMETER_BIN" ]; then
    "$BUILDMETER_BIN" track "$@"
  else
    command "$@"
  fi
}

# `buildmeter report --range week` gibi doğrudan kullanım için.
buildmeter() { "$BUILDMETER_BIN" "$@"; }

for _buildmeter_cmd in flutter fvm dotnet npm pnpm yarn bun npx next vite; do
  eval "${_buildmeter_cmd}() { _buildmeter_track ${_buildmeter_cmd} \"\$@\"; }"
done
unset _buildmeter_cmd
