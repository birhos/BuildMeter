#!/bin/bash
# BuildMeter terminal wrapper'ını repoyu klonlamadan ve Xcode gerektirmeden kurar.
# Dosyalar GitHub'daki ilgili sürüm etiketinden indirilir.
#
# Kullanım:
#   curl -fsSL https://raw.githubusercontent.com/birhos/BuildMeter/v1.0.0/scripts/install-cli.sh | bash
#   curl -fsSL …/install-cli.sh | bash -s -- --uninstall
#   BUILDMETER_VERSION=v1.1.0 scripts/install-cli.sh
#
# --uninstall: ~/.zshrc satırını ve wrapper dosyalarını kaldırır, kayıtlar
# (~/.buildmeter/events.jsonl) korunur.

set -euo pipefail

VERSION="${BUILDMETER_VERSION:-v1.0.0}"
BASE_URL="https://raw.githubusercontent.com/birhos/BuildMeter/$VERSION/cli"
DATA_DIR="$HOME/.buildmeter"
ACTION="${1:-}"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }

install_cli() {
  step "Terminal wrapper'ı indiriliyor ($VERSION)"
  command -v curl >/dev/null || { warn "curl bulunamadı"; exit 1; }

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  local f
  for f in buildmeter-track buildmeter.zsh; do
    curl -fsSL "$BASE_URL/$f" -o "$TMP_DIR/$f" \
      || { warn "İndirilemedi: $BASE_URL/$f"; exit 1; }
  done
  ok "Dosyalar indirildi"

  step "Terminal wrapper'ı kuruluyor"
  mkdir -p "$DATA_DIR/bin"
  install -m 755 "$TMP_DIR/buildmeter-track" "$DATA_DIR/bin/buildmeter-track"
  install -m 644 "$TMP_DIR/buildmeter.zsh" "$DATA_DIR/buildmeter.zsh"
  touch "$DATA_DIR/events.jsonl"
  ok "$DATA_DIR altına kuruldu"

  local line='source "$HOME/.buildmeter/buildmeter.zsh"'
  if ! grep -qF ".buildmeter/buildmeter.zsh" "$HOME/.zshrc" 2>/dev/null; then
    printf '\n# BuildMeter\n%s\n' "$line" >> "$HOME/.zshrc"
    ok "~/.zshrc dosyasına eklendi (yeni terminal açın veya: source ~/.zshrc)"
  else
    ok "~/.zshrc zaten ayarlı"
  fi
}

uninstall_cli() {
  step "Terminal wrapper'ı kaldırılıyor"
  if [ -f "$HOME/.zshrc" ]; then
    sed -i '' '/# BuildMeter/d;/buildmeter\.zsh/d' "$HOME/.zshrc"
    ok "~/.zshrc satırı kaldırıldı"
  fi
  rm -rf "$DATA_DIR/bin" "$DATA_DIR/buildmeter.zsh"
  ok "Wrapper dosyaları kaldırıldı (kayıtlar korundu: $DATA_DIR/events.jsonl)"
  warn "Değişikliğin geçerli olması için yeni bir terminal açın"
}

case "$ACTION" in
  "")          install_cli ;;
  --uninstall) uninstall_cli ;;
  *) warn "Bilinmeyen parametre: $ACTION (kullanım: install-cli.sh [--uninstall])"; exit 1 ;;
esac
