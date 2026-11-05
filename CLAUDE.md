# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

iiire is a macOS 14+ (Apple silicon) menu-bar dictation app. A hotkey records from the mic, the [speech.cpp](https://github.com/nyosegawa/speech.cpp) `speech` binary transcribes locally, and the text is pasted at the cursor. User-facing docs are in `README.md`.

## Tech stack

- Swift 5.10+ / SwiftUI + AppKit. It is a SwiftPM executable with no Xcode project.
- `scripts/build-app.sh` packages the `.app` and signs it.
- speech.cpp is a git submodule at `vendor/speech.cpp`, built with cmake. The resulting `speech` binary is bundled inside the app.

## Commands

```sh
make app                               # → build/iiire.app (speech.cpp + release build + resources + signing)
make run                               # make app, then relaunch it
make test                              # swift test. XCTest needs full Xcode, not just Command Line Tools
swift test --filter AppRuleTests/name  # a single test
```

Verify changes with the built binary instead of the GUI:

```sh
APP=build/iiire.app/Contents/MacOS/iiire
$APP --transcribe FILE.wav [MODEL]
$APP --snapshot-settings DIR    # PNG of every settings tab
$APP --snapshot-hud DIR         # PNG of every HUD state, light and dark
```

## Rules

- Never `defaults write` to the user's real `io.github.pokutuna.iiire` settings to test something. Override for one run with argument-domain flags instead, e.g. `$APP --snapshot-settings DIR -shortcut '' -inputDeviceUID ''`.
- Release builds must not log transcribed text, only its length. `Log` writes to `~/Library/Logs/iiire.log`.
- UI strings are written in English in source and translated in `Resources/ja.lproj/Localizable.strings`. Keep the Japanese text short and plain. Code comments are in Japanese.
- Localization, `Info.plist` and the icon are added only by `build-app.sh`. A plain `swift build` binary is untranslated and has no bundled `speech`. Check UI changes with `make app`.

## Architecture

`AppState` (`Sources/iiire/AppState.swift`) owns everything and drives the phases `idle → recording → transcribing`. Non-obvious points:

- Hotkeys (`Hotkey.swift`): a modifier-only key is watched with `NSEvent` monitors, and a key combo uses Carbon. Both report press and release. A tap is a toggle, and a hold longer than `holdThreshold` (`AppState.swift:33`) is push-to-talk.
- `AudioRecorder` uses CoreAudio AUHAL, not AVAudioEngine, because AVAudioEngine stops when another app reconfigures the mic.
- `SpeechWorker` keeps a `speech worker MODEL` child process and talks JSON Lines to it ([protocol](https://github.com/nyosegawa/speech.cpp/blob/main/docs/worker.md)). The executable lookup order is at `SpeechWorker.swift:37`.
- `TextInserter` pastes through the clipboard and then restores it. Its own key events carry `eventMarker` (`TextInserter.swift:91`), so the hotkey monitor ignores them.
- Settings are in `UserDefaults`. Keys and defaults are in `Settings.swift:150-200`. Per-app output overrides come from `AppRule` / `OutputConfig.resolve`. `Defaults` migrates legacy stored values on read, so keep that code.
- Without the "iiire Local Signing" cert from `make signing-identity`, builds are ad-hoc signed and macOS drops the Accessibility permission on every rebuild.
