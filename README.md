# AI Usage Tracker

Cross-platform desktop tracker for Claude Code, Cursor, and OpenAI Codex on Windows, macOS, and Linux. It runs in the system tray (or macOS menu bar) and reads local session files to estimate usage by day, model, and session. No usage data leaves the computer.

Codex sessions are read from `~/.codex/sessions` on all platforms. Claude and Codex figures are API-equivalent list-price estimates; subscription usage is not billed per token.

## Data sources

| Tool | Location |
| --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Cursor | `%APPDATA%\Cursor` (Windows) · `~/Library/Application Support/Cursor` (macOS) · `~/.config/Cursor` (Linux) |
| OpenAI Codex | `~/.codex/sessions` |

## Phone access (optional)

There's no Android/iOS app — the desktop app can instead serve today's costs and Cost Coach tips to a phone's browser, off by default:

1. Settings → **Phone access** → toggle it on. The desktop app starts a small local HTTP server and shows a link + QR code.
2. Scan the QR code (or open the link) from a phone on the same Wi-Fi network to see the mobile-friendly dashboard.
3. To reach it from outside the house, paste a free [ngrok](https://ngrok.com) authtoken and click "Start remote link." This opens a tunnel through ngrok's servers, so usage data leaves your computer only while that link is active — turn it off when you don't need it.

The link is protected by a random access token baked into the URL/QR code; use "Regenerate access link" to invalidate an old one.

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
