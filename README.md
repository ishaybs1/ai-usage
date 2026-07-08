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

## Fix / develop

```bash
swift build && ./.build/debug/AIUsageTracker --self-test   # 56 checks, runs headless
swift run AIUsageTracker                                    # run the app from source
```

Edit `Sources/AIUsageTracker/…`, keep `--self-test` green, commit, open a PR. After merging,
teammates get the fix with `git pull && ./install.sh`.

Key files: `DataSource/TokenPricing.swift` (rates), `DataSource/CursorPersonalAPI.swift`
(Cursor usage, personal-token endpoint), `ViewModels/UsageViewModel.swift` (aggregation),
`Coach/` (tips + daily digest).

## Update nudges (optional)

The app can show an "Update available" banner in the popover when a teammate is behind. It's
off until you point it at a feed:

1. Host `latest.json` (see the sample in this repo) at a stable URL — a raw git file or an
   Artifactory path. Its `version` is the newest release; `message` is the update command shown.
2. Set the feed URL one of three ways: edit `UpdateChecker.defaultFeedURL`, set the `update.feedURL`
   UserDefaults key, or export `AIUSAGE_UPDATE_URL` (for testing).
3. Bump `latest.json`'s `version` each release. Anyone on an older build sees the nudge on launch.

Verify headlessly: `AIUSAGE_UPDATE_URL=<url> ./.build/debug/AIUsageTracker --update-check`.

## Release

1. Bump `CFBundleShortVersionString` in `package.sh` (and `latest.json` if the feed is enabled).
2. `./package.sh` → distribute `dist/AIUsageTracker.zip`, or push the commit so teammates
   `git pull && ./install.sh`.
3. Keep `./.build/debug/AIUsageTracker --self-test` green (65 checks) before releasing.
