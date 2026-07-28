# AI Usage Tracker

A macOS menu-bar app (🧠) showing your personal **Claude Code + Cursor** spend — today/month,
per-model breakdowns, a daily notification, and a Cost Coach. Everything stays on your Mac.

- **Cursor** = actual charged amount (read from your Cursor login on this Mac).
- **Claude** = estimate, priced from local token logs at list rates (real Enterprise billing
  includes allowances/discounts, so treat it as an upper bound).

## Install / update (from source — recommended)

Requires the Swift toolchain once: `xcode-select --install`.

```bash
git clone git@github.com:ishaybs1/ai-usage.git && cd ai-usage
./install.sh            # build -> /Applications -> auto-start at login -> launch
```

To **update** to the latest later:

```bash
git pull && ./install.sh
```

Uninstall: `./install.sh --uninstall`.

Building locally means no Gatekeeper prompt and no Apple Developer account.

## Install without the toolchain (prebuilt zip)

`./package.sh` produces `dist/AIUsageTracker.zip` (ad-hoc signed) + `INSTALL.txt`. Share the zip;
recipients follow the one-paste command in `INSTALL.txt` (installs, auto-starts, no toolchain).

## What’s included

- Menu-bar totals + dashboard for Claude / Cursor
- Cost Coach tips and optional daily Mac + Slack digests
- **Analyze my transcripts** — ranks expensive local sessions and writes `~/llm-coach-reports/`
- Auto-start via LaunchAgent (no System Events / Apple Music permission prompts)

## Fix / develop

```bash
swift build && ./.build/debug/AIUsageTracker --self-test
swift run AIUsageTracker
```

Edit `Sources/AIUsageTracker/…`, keep `--self-test` green, commit. After merging,
teammates get the fix with `git pull && ./install.sh`.

Key files: `DataSource/TokenPricing.swift` (rates), `DataSource/CursorPersonalAPI.swift`
(Cursor usage), `ViewModels/UsageViewModel.swift` (aggregation), `Coach/` (tips, digests,
transcript analysis).

## Release

1. Bump `VERSION` in `package.sh` / `publish.sh`.
2. `./package.sh` → distribute `dist/AIUsageTracker.zip`, or push so teammates
   `git pull && ./install.sh`.
3. Keep `./.build/debug/AIUsageTracker --self-test` green before releasing.
