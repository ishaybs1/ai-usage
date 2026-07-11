# AI Usage Tracker for Windows

Windows port of the macOS AI Usage app. It runs in the system tray and reads Claude Code and Cursor session files locally to estimate spend by day, model, and session. No usage data leaves the PC.

## Development

Requirements: Node.js, pnpm, Rust, and the [Tauri Windows prerequisites](https://v2.tauri.app/start/prerequisites/).

```powershell
pnpm install
pnpm tauri dev
```

Build the Windows installers:

```powershell
pnpm tauri build
```

The MSI and NSIS installers are written under `src-tauri\target\release\bundle`.
