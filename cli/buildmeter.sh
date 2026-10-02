# BuildMeter — zsh ve bash entegrasyonu.
#   ~/.zshrc:  source ~/.buildmeter/buildmeter.zsh
#   ~/.bashrc: source ~/.buildmeter/buildmeter.sh   (Git Bash dahil)
#
# Build komutlarını süre ölçen `buildmeter track` üzerinden çağırır. Hangi alt komutun
# ölçüleceğine wrapper karar verir; diğerleri (npm install, dotnet test …) olduğu gibi
# çalışır. Geçici olarak kapatmak için: export BUILDMETER_DISABLE=1
#
# Claude Code gibi araçlar profili bir snapshot'a kopyalarken yalnızca fonksiyonları taşır;
# `_` ile başlayan fonksiyonları ve shell değişkenlerini atlar. Bu yüzden fonksiyon adları
# alt çizgisizdir ve binary yolu source anında değil, her çağrıda çözülür.

buildmeter_bin() {
  local bin="${BUILDMETER_BIN:-$HOME/.buildmeter/bin/buildmeter}"
  if [ ! -x "$bin" ] && [ -x "$bin.exe" ]; then
    bin="$bin.exe" # Git Bash
  elif [ ! -x "$bin" ]; then
    # `command -v` aşağıdaki buildmeter() fonksiyonunu bulur; yalnızca PATH'e bakılır.
    if [ -n "${ZSH_VERSION:-}" ]; then
      bin="$(whence -p buildmeter 2>/dev/null)"
    else
      bin="$(type -P buildmeter 2>/dev/null)"
    fi
  fi
  printf '%s\n' "$bin"
}

buildmeter_track() {
  local bin
  bin="$(buildmeter_bin)"
  if [ -z "${BUILDMETER_DISABLE:-}" ] && [ -x "$bin" ]; then
    "$bin" track "$@"
  else
    command "$@"
  fi
}

# `buildmeter report --range week` gibi doğrudan kullanım için.
buildmeter() { "$(buildmeter_bin)" "$@"; }

for _buildmeter_cmd in flutter fvm dotnet npm pnpm yarn bun npx next vite; do
  eval "${_buildmeter_cmd}() { buildmeter_track ${_buildmeter_cmd} \"\$@\"; }"
done
unset _buildmeter_cmd
