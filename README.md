<div align="left">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="branding/logo-wordmark-dark.svg">
        <img alt="BuildMeter logo" src="branding/logo-wordmark.svg">
    </picture>

<h1>Measure the time you spend waiting on Flutter builds</h1>

</div>

BuildMeter records how long you wait for `flutter run` and `flutter build`, and for Flutter debug sessions started from your editor, until the app is up. Records are collected in `~/.buildmeter/events.jsonl`; a macOS menu bar app and widget turn them into daily, weekly and monthly summaries.

## Screenshots

<table>
  <tr>
    <td rowspan="2" valign="top"><img alt="Menu bar window" src="docs/screenshots/menu-bar.png" width="380"></td>
    <td valign="top"><img alt="Medium widget" src="docs/screenshots/widget-medium.png" width="360"></td>
  </tr>
  <tr>
    <td valign="top"><img alt="Medium widget on the desktop (tinted)" src="docs/screenshots/widget-medium-desktop.png" width="360"></td>
  </tr>
</table>

The menu bar window (left) and the medium desktop widget, in full color and as it appears on the desktop when another window is in focus.

## Components

| Component | What it measures | Source |
| --- | --- | --- |
| Terminal wrapper | For `flutter run`, the time until the app is running on the device; for `flutter build`, the whole command. `fvm flutter run\|build` is supported too. | [`cli/`](cli) |
| Editor extension | For Flutter sessions started with F5 / "Start Debugging" in VS Code, Cursor and Antigravity, the time until the `flutter.appStarted` event | [`vscode-extension/`](vscode-extension) |
| macOS app + widget | Live timer in the menu bar, today's total, a 7-day chart, breakdown by project and source; small and medium desktop widgets | [`macos/`](macos) |

## Requirements

- macOS 14.0 or later
- Xcode (`xcodebuild`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- zsh, for the terminal wrapper
- Node.js (the extension is packaged with `npx`) and VS Code 1.80+, Cursor or Antigravity, for the editor extension

## Installation

```bash
git clone https://github.com/birhos/BuildMeter.git
cd BuildMeter
scripts/install.sh
```

In an interactive terminal the script lets you pick components from a menu; the macOS app is always installed. To install specific components:

```bash
scripts/install.sh --all        # everything
scripts/install.sh --app-only   # only /Applications/BuildMeter.app
scripts/install.sh --cli-only   # only ~/.buildmeter + the ~/.zshrc line
scripts/install.sh --ext-only   # only the editor extension
```

After installing:

- Open a new terminal or run `source ~/.zshrc`.
- Run `Developer: Reload Window` in any open editor windows.
- To add the widget, right-click the desktop > Edit Widgets > "BuildMeter".

## Configuration

**Code signing.** Replace `DEVELOPMENT_TEAM` in `macos/project.yml` with your own Apple Developer Team ID (Xcode > Settings > Accounts). If signing with a developer certificate fails, `install.sh` falls back to local signing (Sign to Run Locally).

**Environment variables.**

| Variable | Effect |
| --- | --- |
| `BUILDMETER_DISABLE` | When non-empty, the zsh wrapper is bypassed and commands run directly: `export BUILDMETER_DISABLE=1` |
| `BUILDMETER_DATA_DIR` | Data directory used by the terminal wrapper, the extension and the menu bar app (default `~/.buildmeter`). The widget always reads `~/.buildmeter`. |

## Quick start

Run Flutter commands as usual; the wrapper times them in the background:

```bash
flutter run -d ios
fvm flutter build apk
```

You can also call the wrapper directly, without the shell integration:

```bash
~/.buildmeter/bin/buildmeter-track flutter run -d ios
```

The project name comes from the `name:` field of the first `pubspec.yaml` found walking up from the working directory. Sessions interrupted with Ctrl+C are recorded as `cancelled`, and sessions that exit with an error as `failed`.

To view the raw records in your editor, run `BuildMeter: Olay kayıtlarını aç` from the command palette.

## Reports

Pick a range at the bottom of the menu bar window (today, yesterday, this week, last 7 days, this month, last month):

- **Copy report** — copies a text summary to the clipboard: total wait time, build count, average and longest build, and breakdowns by day, source and project.
- **CSV** — exports the sessions in the selected range as a CSV file.

Concurrent builds count once toward the total wait time; when the plain sum differs from it by more than a minute, the report shows both.

> [!NOTE]
> The app's interface and reports are in Turkish.

## Uninstalling

```bash
scripts/uninstall.sh           # removes the app, extensions and wrapper; keeps your records
scripts/uninstall.sh --purge   # also deletes ~/.buildmeter
```

## License

The editor extension is distributed under the MIT License; see [vscode-extension/LICENSE](vscode-extension/LICENSE).
