# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added
- Auto-collapse: while the AI is thinking, the popup shows fully for 5 seconds, then collapses into a slim right-edge tab (about 18 px wide) so it does not block desktop controls.
- Manual expand: hover or click the edge tab to expand the popup again.
- Automatic expand on new states: new turns, permission requests, and completions expand the popup automatically.

## [1.2.0] - 2026-08-16

### Added
- DeepSeek-style color scheme (`#1E2235` card, `#4D6BFE` running dot).
- Close button (X) on the popup; dismissed popups reappear for the next new turn, permission request, or completion.
- Bilingual documentation (`README.md`, `README.zh.md`), `CONTRIBUTING.md`, `.gitignore`.

### Changed
- Removed click-to-open-webpage behavior from the popup card.
- Hidden the PowerShell console window on Windows and disabled the `Invoke-WebRequest` progress bar.
- Popup script now uses `Show()` + `Dispatcher.Run()` instead of `ShowDialog()` so it stays alive while idle instead of exiting when the window is collapsed.

### Fixed
- `spawnPopup()` never launched the popup because `popupProcess` was initialized to `null` while the guard checked `!== undefined`.
- Popup launched by the plugin exited immediately under idle state (`ShowDialog()` returned for a collapsed window).
- Chinese text in the popup could be garbled on Windows PowerShell 5.1 due to UTF-8 decoding; switched to raw-byte UTF-8 decoding.
- DSH direct `spawn` of PowerShell exited immediately; the plugin now uses a one-shot launcher (`Start-Process`) to create an independent popup process.

## [1.1.0] - 2026-08-16

### Added
- Desktop popup support for Windows (PowerShell + WPF) and macOS/Linux (Python 3 + tkinter).
- Host-side status server (`127.0.0.1:7389/status`).
- Debug logging (`tn-plugin.log`, `tn-launcher.log`, `tn-popup-debug.log`).

## [1.0.0] - 2026-08-15

### Added
- Initial DSH plugin package with persistent bundle mount.
- Browser-side popup (later replaced by native desktop popup in 1.1.0).
