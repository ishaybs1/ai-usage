# AI Usage Tracker

A macOS menu-bar app (🧠) showing your personal **Claude Code + Cursor** spend — today/month,
per-model breakdowns, a daily notification, and a Cost Coach. Everything stays on your Mac.

- **Cursor** = actual charged amount (read from your Cursor login on this Mac).
- **Claude** = estimate, priced from local token logs at list rates (real Enterprise billing
  includes allowances/discounts, so treat it as an upper bound).

## Install / update (from source — recommended)

Requires the Swift toolchain once: `xcode-select --install`.

```bash
git clone <this-repo-url> && cd AIUsageTracker
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

## Release

Bump `CFBundleShortVersionString` in `package.sh`, run `./package.sh`, then distribute the zip
(or push the commit so teammates `git pull && ./install.sh`).
