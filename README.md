# AI Usage Tracker for macOS and Windows

Cross-platform desktop tracker for Claude Code, Cursor, and OpenAI Codex. It runs in the macOS menu bar or Windows system tray and reads local session files to estimate usage by day, model, and session. No usage data leaves the computer.

Codex sessions are read from `~/.codex/sessions` on both platforms. Codex figures are API-equivalent estimates; ChatGPT and Codex subscription usage is not billed per token.

## Development

Requirements: Node.js, pnpm, Rust, and the [Tauri platform prerequisites](https://v2.tauri.app/start/prerequisites/).

```powershell
pnpm install
pnpm tauri dev
```

Build the installers for the current platform:

```powershell
pnpm tauri build
```

Platform packages are written under `src-tauri/target/release/bundle`: MSI/NSIS on Windows and DMG/app bundles on macOS.
