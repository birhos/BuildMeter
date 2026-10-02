#!/bin/bash
# BuildMeter kurulumu:
#   1) macOS menü bar uygulaması + widget  -> /Applications
#   2) Terminal wrapper'ı                   -> ~/.buildmeter + ~/.zshrc
#   3) VS Code / Cursor / Antigravity eklentisi (seçilen editörlerin tüm profillerine)
#   4) .NET için MSBuild hook'u (dotnet build, Rider)  -> MSBuild ImportAfter klasörü
#
# Kullanım: scripts/install.sh [--all | --app-only | --cli-only | --ext-only | --dotnet]
# Parametresiz ve etkileşimli terminalde kurulacak adımlar menüden seçilir.

# "sh install.sh" ile çağrıldıysa bash (POSIX modu dışında) ile yeniden başlat.
if [ -z "${BASH_VERSION:-}" ] || shopt -qo posix 2>/dev/null; then exec /bin/bash "$0" "$@"; fi

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$HOME/.buildmeter"
APP_NAME="BuildMeter.app"
# MSBuild, kullanıcı düzeyindeki bu klasördeki .targets dosyalarını her projeye ekler.
MSBUILD_IMPORT_AFTER="$HOME/.local/share/Microsoft/MSBuild/Current/Microsoft.Common.targets/ImportAfter"
ONLY="${1:-}"

banner() {
  local c=$'\033[38;5;45m' b=$'\033[38;5;33m' v=$'\033[38;5;135m' o=$'\033[38;5;208m' r=$'\033[38;5;202m'
  local w=$'\033[1;97m' d=$'\033[2m' x=$'\033[0m'
  printf '\n'
  printf '      %s▄▄%s▄▄▄%s▄▄%s▄▄%s\n'                      "$c" "$b" "$v" "$o" "$x"
  printf '   %s▄▀%s           %s▀▄%s     %sBuild%sMeter%s\n'  "$c" "$x" "$r" "$x" "$w" "$o" "$x"
  printf '  %s█%s      %s●%s━━━━%s▶%s   %s█%s    %sBuild bekleme süresi ölçer%s\n' \
         "$c" "$x" "$r" "$w" "$r" "$x" "$d" "$x" "$d" "$x"
  printf '   %s▀▄%s           %s▄▀%s\n'                        "$c" "$x" "$d" "$x"
  printf '\n'
}

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }

# Desteklenen editörler: "ad|cli|Application Support dizini"
EDITORS=(
  "VS Code|/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code|$HOME/Library/Application Support/Code"
  "Cursor|/Applications/Cursor.app/Contents/Resources/app/bin/cursor|$HOME/Library/Application Support/Cursor"
  "Antigravity|/Applications/Antigravity IDE.app/Contents/Resources/app/bin/antigravity-ide|$HOME/Library/Application Support/Antigravity IDE"
  "Antigravity|/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity|$HOME/Library/Application Support/Antigravity"
)
SELECTED_EDITORS=() # boşsa tüm bulunan editörler

# Makinede kurulu (cli'ı çalıştırılabilir) editörlerin adlarını listeler.
installed_editors() {
  local entry name cli support
  for entry in "${EDITORS[@]}"; do
    IFS='|' read -r name cli support <<<"$entry"
    [ -x "$cli" ] && echo "$name"
  done
}

editor_selected() { # name
  [ ${#SELECTED_EDITORS[@]} -eq 0 ] && return 0
  local e
  for e in "${SELECTED_EDITORS[@]}"; do [ "$e" = "$1" ] && return 0; done
  return 1
}

# for_each_editor_profile <fonksiyon> <argümanlar…>: her editör ve profil için
# <fonksiyon> "<editör adı>" "<cli>" "<profil|boş>" <argümanlar…> çağırır.
# Yalnızca seçilen editörler dolaşılır.
for_each_editor_profile() {
  local fn="$1"; shift
  local entry name cli support profile
  for entry in "${EDITORS[@]}"; do
    IFS='|' read -r name cli support <<<"$entry"
    [ -x "$cli" ] || continue
    editor_selected "$name" || continue
    local profiles=("")
    while IFS= read -r profile; do [ -n "$profile" ] && profiles+=("$profile"); done < <(editor_profiles "$support")
    for profile in "${profiles[@]}"; do
      "$fn" "$name" "$cli" "$profile" "$@"
    done
  done
}

install_ext_into() { # name cli profile vsix
  local args=(--install-extension "$4" --force)
  [ -n "$3" ] && args+=(--profile "$3")
  "$2" "${args[@]}" >/dev/null 2>&1 \
    && ok "$1 eklentisi kuruldu (profil: ${3:-varsayılan})" \
    || warn "$1 eklentisi kurulamadı (profil: ${3:-varsayılan})"
}

install_app() {
  step "macOS uygulaması derleniyor"
  command -v xcodegen >/dev/null || { warn "xcodegen gerekli: brew install xcodegen"; exit 1; }
  cd "$ROOT/macos"
  xcodegen generate --quiet

  local build_args=(-project BuildMeter.xcodeproj -scheme BuildMeter
                    -configuration Release -derivedDataPath build)
  if xcodebuild "${build_args[@]}" -allowProvisioningUpdates build >build.log 2>&1; then
    ok "Apple Development sertifikasıyla imzalandı"
  else
    warn "Geliştirici sertifikasıyla imzalanamadı (Xcode > Settings > Accounts oturumunu kontrol edin)."
    warn "Yerel imza (Sign to Run Locally) ile derleniyor…"
    xcodebuild "${build_args[@]}" CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual build >build.log 2>&1 \
      || { warn "Derleme başarısız, ayrıntılar: macos/build.log"; exit 1; }
    ok "Yerel imza ile derlendi"
  fi

  pkill -x BuildMeter 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x BuildMeter >/dev/null || break; sleep 0.3; done
  rm -rf "/Applications/$APP_NAME"
  cp -R "build/Build/Products/Release/$APP_NAME" /Applications/
  open "/Applications/$APP_NAME"
  ok "/Applications/$APP_NAME kuruldu ve başlatıldı"
  cd "$ROOT"
}

install_cli() {
  step "Terminal wrapper'ı kuruluyor"
  mkdir -p "$DATA_DIR/bin"
  install -m 755 "$ROOT/cli/buildmeter-track" "$DATA_DIR/bin/buildmeter-track"
  install -m 644 "$ROOT/cli/buildmeter.zsh" "$DATA_DIR/buildmeter.zsh"
  touch "$DATA_DIR/events.jsonl"

  local line='source "$HOME/.buildmeter/buildmeter.zsh"'
  if ! grep -qF ".buildmeter/buildmeter.zsh" "$HOME/.zshrc" 2>/dev/null; then
    printf '\n# BuildMeter\n%s\n' "$line" >> "$HOME/.zshrc"
    ok "~/.zshrc dosyasına eklendi (yeni terminal açın veya: source ~/.zshrc)"
  else
    ok "~/.zshrc zaten ayarlı"
  fi
}

install_dotnet() {
  step ".NET için MSBuild hook'u kuruluyor"
  mkdir -p "$MSBUILD_IMPORT_AFTER" "$DATA_DIR"
  install -m 644 "$ROOT/cli/msbuild/BuildMeter.targets" "$MSBUILD_IMPORT_AFTER/BuildMeter.targets"
  touch "$DATA_DIR/events.jsonl"
  ok "dotnet build ve Rider build'leri kaydedilecek"
  command -v dotnet >/dev/null || warn "dotnet bulunamadı; hook SDK kurulduğunda devreye girer"
}

# VS Code tabanlı editörlerin profil adlarını listeler (User/globalStorage/storage.json).
editor_profiles() {
  local storage="$1/User/globalStorage/storage.json"
  [ -f "$storage" ] || return 0
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const p of d.userDataProfiles || []) console.log(p.name);
  ' "$storage" 2>/dev/null || true
}

install_ext() {
  step "Editör eklentisi paketleniyor"
  cd "$ROOT/vscode-extension"
  npx --yes @vscode/vsce@latest package --out buildmeter.vsix >/dev/null
  ok "buildmeter.vsix oluşturuldu"

  for_each_editor_profile install_ext_into "$PWD/buildmeter.vsix"
  warn "Açık editör pencerelerinde: Developer: Reload Window"
  cd "$ROOT"
}

# multi_select <sonuç dizisi adı> <etiket>…: ok tuşları + boşluk ile çoklu seçim.
# Etiket "!" ile başlıyorsa zorunludur (hep seçili, değiştirilemez).
# Seçili öğelerin indeksleri sonuç dizisine yazılır.
multi_select() {
  local out="$1"; shift
  local labels=("$@") n=$# cur=0 i key esc=$'\033'
  local checked=() locked=()
  for ((i = 0; i < n; i++)); do
    checked[i]=1; locked[i]=0
    if [ "${labels[i]:0:1}" = "!" ]; then locked[i]=1; labels[i]="${labels[i]:1}"; fi
  done

  draw() {
    for ((i = 0; i < n; i++)); do
      local box="[ ]" ptr="  " line
      [ "${checked[i]}" = 1 ] && box="[\033[32m✓\033[0m]"
      [ $i -eq $cur ] && ptr="\033[1;36m❯\033[0m "
      line="${labels[i]}"
      [ "${locked[i]}" = 1 ] && line="$line \033[2m(zorunlu)\033[0m"
      printf '\033[2K    %b%b %b\n' "$ptr" "$box" "$line"
    done
    printf '\033[2K    \033[2m↑/↓ gezin · boşluk seç · a hepsi · enter onayla\033[0m\n'
  }

  printf '\033[?25l'
  trap 'printf "\033[?25h"' EXIT
  draw
  while true; do
    IFS= read -rsn1 key </dev/tty
    if [ "$key" = "$esc" ]; then
      IFS= read -rsn2 key </dev/tty
      case "$key" in
        "[A") cur=$(( (cur - 1 + n) % n )) ;;
        "[B") cur=$(( (cur + 1) % n )) ;;
      esac
    else
      case "$key" in
        " ") [ "${locked[cur]}" = 1 ] || checked[cur]=$(( 1 - checked[cur] )) ;;
        k) cur=$(( (cur - 1 + n) % n )) ;;
        j) cur=$(( (cur + 1) % n )) ;;
        a)
          local all=1
          for ((i = 0; i < n; i++)); do [ "${locked[i]}" = 1 ] || [ "${checked[i]}" = 1 ] || all=0; done
          for ((i = 0; i < n; i++)); do [ "${locked[i]}" = 1 ] || checked[i]=$(( 1 - all )); done
          ;;
        "") break ;;
      esac
    fi
    printf '\033[%dA' $((n + 1))
    draw
  done
  printf '\033[?25h'

  eval "$out=()"
  for ((i = 0; i < n; i++)); do
    [ "${checked[i]}" = 1 ] && eval "$out+=($i)"
  done
  return 0
}

DO_CLI=1
DO_EXT=1
DO_DOTNET=1

# Kurulacak adımları kullanıcıya sorar. Uygulama her zaman kurulur.
choose_steps() {
  local editors=() labels=("!macOS uygulaması + widget" "CLI (terminal wrapper)" ".NET (MSBuild hook'u)") e
  while IFS= read -r e; do [ -n "$e" ] && editors+=("$e"); done < <(installed_editors | awk '!seen[$0]++')
  for e in "${editors[@]+"${editors[@]}"}"; do labels+=("Eklenti: $e"); done

  printf '\n  \033[1mKurulacak bileşenleri seçin:\033[0m\n\n'
  local picked=()
  multi_select picked "${labels[@]}"

  DO_CLI=0; DO_EXT=0; DO_DOTNET=0; SELECTED_EDITORS=()
  local idx
  for idx in "${picked[@]+"${picked[@]}"}"; do
    case "$idx" in
      0) ;;
      1) DO_CLI=1 ;;
      2) DO_DOTNET=1 ;;
      *) DO_EXT=1; SELECTED_EDITORS+=("${editors[idx - 3]}") ;;
    esac
  done
}

banner

case "$ONLY" in
  --app-only) install_app ;;
  --cli-only) install_cli ;;
  --ext-only) install_ext ;;
  --dotnet)   install_dotnet ;;
  --all)      install_cli; install_dotnet; install_ext; install_app ;;
  "")
    # Etkileşimsiz çalıştırmada (ör. curl | bash) her şey kurulur.
    [ -t 0 ] && [ -t 1 ] && choose_steps
    [ "$DO_CLI" = 1 ] && install_cli
    [ "$DO_DOTNET" = 1 ] && install_dotnet
    [ "$DO_EXT" = 1 ] && install_ext
    install_app
    ;;
  *) warn "Bilinmeyen parametre: $ONLY"; exit 1 ;;
esac

step "Bitti"
echo "    Widget: masaüstüne sağ tık > Widget'ları Düzenle > 'BuildMeter'"
