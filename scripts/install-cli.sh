#!/bin/bash
# BuildMeter terminal wrapper'ını repoyu klonlamadan ve Go/Xcode gerektirmeden kurar.
# Binary ve shim, GitHub release'inden indirilir ve checksum'ı doğrulanır.
#
# Kullanım:
#   curl -fsSL https://raw.githubusercontent.com/birhos/BuildMeter/main/scripts/install-cli.sh | bash
#   curl -fsSL …/install-cli.sh | bash -s -- --uninstall
#   BUILDMETER_VERSION=v1.1.0 scripts/install-cli.sh
#
# --uninstall: shell satırlarını ve wrapper dosyalarını kaldırır, kayıtlar
# (~/.buildmeter/events.jsonl) korunur.

set -euo pipefail

VERSION="${BUILDMETER_VERSION:-latest}"
if [ "$VERSION" = "latest" ]; then
  BASE_URL="https://github.com/birhos/BuildMeter/releases/latest/download"
else
  BASE_URL="https://github.com/birhos/BuildMeter/releases/download/$VERSION"
fi
DATA_DIR="$HOME/.buildmeter"
ACTION="${1:-}"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }

add_rc_line() { # dosya satır aranacak_metin
  if grep -qF "$3" "$1" 2>/dev/null; then
    ok "$(basename "$1") zaten ayarlı"
  else
    printf '\n# BuildMeter\n%s\n' "$2" >> "$1"
    ok "$(basename "$1") dosyasına eklendi (yeni terminal açın veya: source ~/$(basename "$1"))"
  fi
}

install_cli() {
  step "Terminal wrapper'ı indiriliyor ($VERSION)"
  command -v curl >/dev/null || { warn "curl bulunamadı"; exit 1; }
  local asset
  case "$(uname -s)" in
    Darwin) asset="buildmeter-darwin-universal" ;;
    Linux)
      case "$(uname -m)" in
        x86_64) asset="buildmeter-linux-amd64" ;;
        aarch64|arm64) asset="buildmeter-linux-arm64" ;;
        *) warn "Desteklenmeyen mimari: $(uname -m)"; exit 1 ;;
      esac ;;
    *) warn "Desteklenmeyen sistem: $(uname -s) (Windows için scripts/install.ps1)"; exit 1 ;;
  esac

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  local f
  for f in "$asset" buildmeter.sh checksums.txt; do
    curl -fsSL "$BASE_URL/$f" -o "$TMP_DIR/$f" || { warn "İndirilemedi: $BASE_URL/$f"; exit 1; }
  done
  (cd "$TMP_DIR" && grep -E " ($asset|buildmeter\.sh)\$" checksums.txt | shasum -a 256 -c - >/dev/null) \
    || { warn "Checksum doğrulanamadı"; exit 1; }
  ok "Dosyalar indirildi ve doğrulandı"

  step "Terminal wrapper'ı kuruluyor"
  mkdir -p "$DATA_DIR/bin"
  install -m 755 "$TMP_DIR/$asset" "$DATA_DIR/bin/buildmeter"
  ln -sf buildmeter "$DATA_DIR/bin/buildmeter-track"
  install -m 644 "$TMP_DIR/buildmeter.sh" "$DATA_DIR/buildmeter.sh"
  install -m 644 "$TMP_DIR/buildmeter.sh" "$DATA_DIR/buildmeter.zsh"
  touch "$DATA_DIR/events.jsonl"
  ok "$DATA_DIR altına kuruldu"

  add_rc_line "$HOME/.zshrc" 'source "$HOME/.buildmeter/buildmeter.zsh"' ".buildmeter/buildmeter.zsh"
  [ -f "$HOME/.bashrc" ] && add_rc_line "$HOME/.bashrc" 'source "$HOME/.buildmeter/buildmeter.sh"' ".buildmeter/buildmeter.sh"
  return 0
}

uninstall_cli() {
  step "Terminal wrapper'ı kaldırılıyor"
  local rc
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || continue
    sed -i.bak '/# BuildMeter/d;/buildmeter\.zsh/d;/buildmeter\.sh/d' "$rc" && rm -f "$rc.bak"
    ok "$(basename "$rc") satırı kaldırıldı"
  done
  rm -rf "$DATA_DIR/bin" "$DATA_DIR/buildmeter.zsh" "$DATA_DIR/buildmeter.sh"
  ok "Wrapper dosyaları kaldırıldı (kayıtlar korundu: $DATA_DIR/events.jsonl)"
  warn "Değişikliğin geçerli olması için yeni bir terminal açın"
}

case "$ACTION" in
  "")          install_cli ;;
  --uninstall) uninstall_cli ;;
  *) warn "Bilinmeyen parametre: $ACTION (kullanım: install-cli.sh [--uninstall])"; exit 1 ;;
esac
