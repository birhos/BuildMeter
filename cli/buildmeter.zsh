# BuildMeter — zsh entegrasyonu.
# ~/.zshrc içine: source ~/.buildmeter/buildmeter.zsh
#
# `flutter run`, `flutter build`, `fvm flutter run|build` komutlarını süre ölçerek çalıştırır.
# Diğer tüm komutlar olduğu gibi geçer. Geçici olarak kapatmak için: export BUILDMETER_DISABLE=1

BUILDMETER_TRACK="${BUILDMETER_TRACK:-$HOME/.buildmeter/bin/buildmeter-track}"

flutter() {
  if [[ -z "$BUILDMETER_DISABLE" && -x "$BUILDMETER_TRACK" && ( "$1" == run || "$1" == build ) ]]; then
    "$BUILDMETER_TRACK" "${commands[flutter]:-flutter}" "$@"
  else
    command flutter "$@"
  fi
}

fvm() {
  if [[ -z "$BUILDMETER_DISABLE" && -x "$BUILDMETER_TRACK" && "$1" == flutter && ( "$2" == run || "$2" == build ) ]]; then
    "$BUILDMETER_TRACK" "${commands[fvm]:-fvm}" "$@"
  else
    command fvm "$@"
  fi
}
