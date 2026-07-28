# AI Usage Tracker

Cross-platform desktop tracker for Claude Code, Cursor, and OpenAI Codex on Windows, macOS, and Linux. It runs in the system tray (or macOS menu bar) and reads local session files to estimate usage by day, model, and session. No usage data leaves the computer.

Codex sessions are read from `~/.codex/sessions` on all platforms. Claude and Codex figures are API-equivalent list-price estimates; subscription usage is not billed per token.

## Data sources

| Tool | Location |
| --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Cursor | `%APPDATA%\Cursor` (Windows) · `~/Library/Application Support/Cursor` (macOS) · `~/.config/Cursor` (Linux) |
| OpenAI Codex | `~/.codex/sessions` |

## Development

Requirements: Node.js, pnpm, Rust, and the [Tauri platform prerequisites](https://v2.tauri.app/start/prerequisites/). On Linux this includes `libwebkit2gtk-4.1-dev` and, for the tray icon, `libayatana-appindicator3-dev`.

```powershell
pnpm install
pnpm tauri dev
```

Build the installers for the current platform:

```powershell
pnpm tauri build
```

Platform packages are written under `src-tauri/target/release/bundle`: MSI/NSIS on Windows, DMG/app bundles on macOS, and deb/AppImage on Linux.
