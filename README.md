# wifiscan

[![CI](https://github.com/lucasdaddiego/wifiscan/actions/workflows/ci.yml/badge.svg)](https://github.com/lucasdaddiego/wifiscan/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/platform-macOS%2012%2B-black?logo=apple)
![language](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![license](https://img.shields.io/badge/license-MIT-blue)

A terminal **Wi‑Fi survey & channel planner** for modern macOS, driven straight off
**CoreWLAN**. One scan, one screen: every nearby network with its **name, power,
SNR, channel, band, width and security** — sortable on any column, with a live
**channel‑congestion map** and a **"cleanest channel" recommendation per band** so
you can pick the best channel for each of your access points.

A single self‑contained Swift binary. No Homebrew, no Python, no `pip`, no
third‑party packages.

```
 wifiscan   iface en0   connected home-router   location authorized
 networks 22  shown 22   view list   sort Power↓   filter All bands   auto on(6s)   last 19:44
 ────────────────────────────────────────────────────────────────────────────────────────
 SSID                   Chan  Band  Width   dBm  Signal        SNR  Sec
 home-router               6  2.4     20   -34   ██████████      —  WPA2/3
 Neighbour_2G             11  2.4     20   -36   █████████·      —  WPA2/3
 home-router-5G          161  5       80   -45   ████████··     49  WPA2/3
 FiberHome-A1              1  2.4     20   -48   ███████···      —  WPA2/3
 office-mesh              44  5       80   -49   ███████···      —  WPA3
 TP-Link_4F2A              3  2.4     40   -66   ████······      —  WPA2/3
 ISP-WiFi-9021           157  5       80   -73   ███·······      —  WPA2/3
 guest-5G                 36  5       80   -80   ██········      —  WPA2/3
 …
 ────────────────────────────────────────────────────────────────────────────────────────
 Recommended clean channels
   2.4 GHz   ch 1 (3ap)   ch 11 (4ap)   ch 6 (9ap)     only 1/6/11 are non-overlapping
   5 GHz     ch 36 (1ap)  ch 40 (1ap)   ch 44 (2ap)    non-DFS (preferred)
             ch 100 (0ap) ch 104 (0ap)  ch 108 (0ap)   DFS* — cleaner, but may drop on radar
 ────────────────────────────────────────────────────────────────────────────────────────
 [q]uit  [?]help  [r]escan  [g]raph  [a]uto  sort p/s/c/n/w/e/[l]oad  [b]and 1/2/6/0  j/k u/d scroll  [+/-]interval
```

## Contents

- [Features](#features)
- [Why a custom tool?](#why-a-custom-tool)
- [Requirements](#requirements)
- [Install](#install)
- [First run: grant Location Services](#first-run-grant-location-services)
- [Usage](#usage)
- [Reading the table](#reading-the-table)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [The channel map](#the-channel-map)
- [How recommendations work](#how-recommendations-work)
- [Survey over time](#survey-over-time)
- [JSON output](#json-output)
- [How it reveals SSIDs (the macOS‑26 catch)](#how-it-reveals-ssids-the-macos26-catch)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Known macOS limitations](#known-macos-limitations)
- [Project layout](#project-layout)
- [Development](#development)
- [License](#license)

## Features

- **Full neighbour survey** — SSID, RSSI (dBm), SNR, channel, band (2.4 / 5 / 6 GHz),
  channel width (20/40/80/160/320 MHz), security (Open / WEP / WPA / WPA2 / WPA3 /
  transition) and **QBSS channel load** (the AP's own airtime‑utilisation broadcast,
  when present).
- **Sort by any column** live — power, SNR, channel, name, band, width, security,
  load; press a key again to reverse.
- **Channel‑congestion map** — a power‑weighted occupancy bar per channel, per band,
  that accounts for channel‑bonding overlap.
- **"Cleanest channel" recommendations** per band — energy‑weighted interference
  scoring with partial‑overlap fractions and QBSS airtime, **your own APs excluded**
  (connected SSID automatically, more via `--exclude-ssid`), with **dB margins** so
  you can see whether the runner‑up actually matters.
- **Survey over time** — `--log` appends every scan to a JSONL file; `--report`
  aggregates it into the cleanest channel **per hour of day** plus a minimax
  all‑day pick (congestion at 9 pm ≠ congestion at 4 am).
- **Colour‑coded signal** bars and dBm, from bright‑green (excellent) to red (poor) —
  a smooth **24‑bit gradient** with **sub‑cell (⅛‑block) bars** on truecolor terminals
  (Ghostty, iTerm, kitty …), gracefully falling back to a 256‑colour palette elsewhere.
- **Modern‑terminal niceties** — flicker‑free **synchronized** frame updates, **mouse**
  (wheel‑scroll, click a header to sort) and a live **window/tab title**; all auto‑gated,
  so dumb terminals and pipes still work.
- **Live auto‑refresh** with adjustable interval, plus on‑demand rescan.
- **Band filters** (2.4 / 5 / 6 GHz / all), scrolling and paging for crowded areas,
  a `?` help overlay, and view settings that **persist across runs**
  (`~/.config/wifiscan/config.json`).
- **Scriptable** — `--once`, `--json` (pipe into `jq`), `--diag`, `--log`/`--report`,
  `--band`, `--sort`.
- **Single static binary**, packaged as a signed `.app`; **zero dependencies**.

## Why a custom tool?

On **macOS 14.4+ Apple removed the `airport` CLI**, and there's no maintained, free
TUI scanner that returns neighbour RSSI / channel / width. The only API that still
does is **CoreWLAN** (`CWWiFiClient`), which `wifiscan` drives directly in Swift —
so it works on the latest macOS with nothing to install.

## Requirements

- **macOS** (built & tested on **macOS 26 / Apple Silicon**; targets macOS 12+).
- **Xcode Command Line Tools** for `swiftc` — `xcode-select --install`.
- That's it. No Homebrew formulae, no Swift packages.

## Install

```sh
git clone https://github.com/lucasdaddiego/wifiscan.git
cd wifiscan
make            # build wifiscan.app into ~/Applications + a `wifiscan` launcher on ~/.bin
make clean      # remove both
```

`make` compiles an optimised, fully‑stripped binary (no debug info), embeds an
`Info.plist`, ad‑hoc code‑signs it inside **`~/Applications/wifiscan.app`**, and
symlinks a **`wifiscan`** command into **`~/.bin`**.

Make sure `~/.bin` is on your `PATH`:

```sh
echo 'export PATH="$HOME/.bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Then run `wifiscan` from any terminal, or **double‑click `wifiscan.app`** — it
reopens itself inside your terminal (Ghostty, iTerm, then Terminal, whichever is
installed) and runs the TUI.

## First run: grant Location Services

macOS hides Wi‑Fi **SSIDs** unless the scanning app has **Location Services**
permission. `wifiscan` ships as a signed `.app`, so it shows up in that list under
its own name:

1. Run `wifiscan` (or `wifiscan --diag`) once.
2. **System Settings → Privacy & Security → Location Services** → enable **wifiscan**.
3. Run `wifiscan` again. `wifiscan --diag` should report **`SSIDs visible: N/N`**.

Power, channel, band, width and security all work **without** this — only the
network *names* are gated.

### Keep the grant across rebuilds (optional)

Ad‑hoc signing gives the app a new identity on every `make`, so macOS forgets the
grant and you'd have to re‑enable it. To make the grant **stick across rebuilds**,
sign with a stable self‑signed certificate:

1. **Keychain Access → Certificate Assistant → Create a Certificate…**
   - Name: e.g. `wifiscan-codesign`
   - Identity Type: **Self Signed Root**
   - Certificate Type: **Code Signing**
2. Create a git‑ignored `Makefile.local`:
   ```make
   SIGN := wifiscan-codesign
   ```
3. `make` now signs with that identity. Grant Location once; every future build
   keeps it.

(The public repo defaults to ad‑hoc signing, so `make` works for everyone with no
setup.)

## Usage

```sh
wifiscan                            # interactive TUI (default)
wifiscan --once                     # one scan: table + channel map + recommendations, then exit
wifiscan --json                     # one scan as JSON on stdout (pipe into jq, etc.)
wifiscan --diag                     # scan + permission diagnostics
wifiscan --log ~/wifi-survey.jsonl  # TUI as usual, but append every scan to a survey log
wifiscan --report ~/wifi-survey.jsonl   # aggregate that log: cleanest channel by hour
wifiscan --help                     # usage summary
```

| Flag | Description |
|------|-------------|
| `--once` | Single scan; print the table, channel map and recommendations, then exit. |
| `--json` | Single scan; emit a JSON array on stdout. |
| `--diag` | Print interface, permission status, network/SSID counts and the app bundle path. |
| `--band 2.4\|5\|6\|all` | Filter to one band (initial TUI filter, or the one‑shot output). |
| `--sort key` | Initial sort: `power`, `snr`, `channel`, `name`, `band`, `width`, `security`, `load`. |
| `--exclude-ssid a[,b]` | Keep your own network(s) out of the recommendation model. The connected SSID is always excluded. |
| `--log file` | Append every completed scan to `file` as JSONL (works in TUI and one‑shot modes). |
| `--report file` | Read a `--log` file and print the cleanest channel per hour of day + an all‑day pick, per band. |
| `--help`, `-h` | Show usage. |

Everything else is a **live** TUI control. Sort column, band filter and refresh
interval are changed with keys while running (see
[keyboard shortcuts](#keyboard-shortcuts)) and are **remembered across runs** in
`~/.config/wifiscan/config.json` (flags override). **Colour is automatic**: on in a
terminal, off when piped or redirected. Set `NO_COLOR` to force it off. **Truecolor**
is used when the terminal advertises it (`COLORTERM=truecolor`, as Ghostty/iTerm/kitty
do); otherwise the 256‑colour palette is used.

## Reading the table

| Column | Meaning |
|--------|---------|
| **SSID** | Network name. `‹hidden›` = a network not broadcasting its name. A `▸` marks the network you're connected to. |
| **Chan** | Primary (control) channel number. |
| **Band** | `2.4`, `5`, or `6` GHz — each tinted its own colour (amber / blue / violet) for quick grouping. |
| **Width** | Channel width in MHz: `20` / `40` / `80` / `160`. |
| **dBm** | RSSI / signal power. Closer to 0 is stronger (e.g. `-45` ≫ `-85`). |
| **Signal** | Colour bar of the same value. |
| **SNR** | Signal‑to‑noise ratio in dB — only shown for the channel your radio is tuned to (see [limitations](#known-macos-limitations)); `—` otherwise. |
| **Load** | The AP's own **QBSS airtime utilisation** broadcast (`42%` = its channel is busy 42% of the time), green → red. `—` when the AP doesn't broadcast it. RSSI says *loud*; this says *busy*. Shown on wide terminals. |
| **Sec** | Security: `Open`, `WEP`, `WPA`, `WPA2`, `WPA3`, or `WPA2/3` (transition). |
| **Trend** | Sparkline of recent RSSI samples (last ~12 refreshes), so you can see a signal drifting or fluctuating at a glance. Shown on wide terminals only. |

**Signal colour key** (by dBm): bright‑green `≥ -50` · green `-50…-60` · yellow
`-60…-67` · orange `-67…-75` · red `< -75`. On truecolor terminals this is a smooth
gradient rather than five steps.

## Keyboard shortcuts

| Key | Action | | Key | Action |
|-----|--------|-|-----|--------|
| `q` / `Esc` / `Ctrl‑C` / `Ctrl‑D` | quit | | `p` | sort by **p**ower |
| `?` | help overlay (any key closes) | | `s` | sort by **S**NR |
| `r` | **r**escan now | | `c` | sort by **c**hannel |
| `g` / `Tab` | toggle **g**raph (channel map) | | `n` | sort by **n**ame |
| `a` | toggle **a**uto‑refresh | | `w` | sort by **w**idth |
| `b` | cycle **b**and filter | | `e` | sort by s**e**curity |
| `1` / `2` / `6` | filter to 2.4 / 5 / 6 GHz | | `l` | sort by **l**oad (QBSS airtime) |
| `0` | show all bands | | `j` / `k` | scroll down / up |
| `+` / `-` | refresh interval ± 1s | | `u` / `d` / `Space` | scroll 10 lines |
| | | | | press a sort key again to reverse |

### Mouse

On terminals with mouse reporting (Ghostty, iTerm, kitty, Terminal.app …):

- **Scroll wheel** — scroll the network list / channel map.
- **Click a column header** — sort by that column (click again to reverse).

Mouse reporting takes over click‑drag, so to **select/copy** text hold **Shift** while
dragging (the standard terminal bypass).

## The channel map

Press `g` (or `Tab`) for the congestion view. Per band, each occupied channel gets
a **power‑weighted bar** — the summed signal energy that lands on it — so crowding
is obvious at a glance:

```
 ▎ 2.4 GHz  (12 networks)
    ch 1    3ap  -48dBm  ███████
    ch 6    9ap  -34dBm  ████████████████████████████████████████
    ch 11   4ap  -36dBm  ██████████

 ▎ 5 GHz  (10 networks)
   ch 36    1ap  -49dBm  ██████████
   ch 161   3ap  -45dBm  ████████████████████████████████████████  DFS
```

`Nap` is the number of APs overlapping that channel; the dBm is the strongest of
them; the bar's **colour** tracks congestion too (green = quiet → red = busiest in
the band), so colour and length tell the same story. `DFS` marks 5 GHz channels
subject to radar detection.

## How recommendations work

1. Each AP is mapped to the **frequency span** it actually occupies, accounting for
   20 / 40 / 80 / 160 / 320 MHz channel bonding — standard 5 GHz bonded groups, the
   regular 6 GHz grid, and centre‑frequency overlap for 2.4 GHz.
2. For each candidate channel, `wifiscan` sums the **linear power** (`10^(RSSI/10)`)
   of every overlapping AP, scaled by the **fraction of its spectrum that actually
   lands on the candidate** (an 80 MHz AP spreads its energy, so a 20 MHz slot
   inside it sees a quarter; a 2.4 GHz AP two channels over counts half). A strong
   nearby AP therefore counts far more than a weak distant one — better than naïve
   "AP count" tools.
3. When an AP broadcasts **QBSS airtime utilisation**, its contribution is scaled by
   how busy it actually is (floored at 10% — an idle AP still beacons and can wake
   up). APs that don't broadcast it are assumed busy.
4. **Your own networks are excluded** — the connected SSID automatically, others via
   `--exclude-ssid`. Moving your AP moves its energy with it, so counting it would
   bias the recommendation away from wherever your AP currently sits. The heading
   shows what was ignored.
5. The channel with the **least overlapping energy** wins. Runners‑up carry a
   **`+N dB` margin** (`+3dB` ≈ twice the interfering energy), so you can tell
   "effectively tied" from "clearly worse".

Per band:

- **2.4 GHz** → only ever recommends **1 / 6 / 11** (the non‑overlapping set).
- **5 GHz** → best **non‑DFS** channel (`36/40/44/48/149/153/157/161/165`), plus the
  cleanest **DFS** option marked `*` (cleaner, but can momentarily drop on radar
  detection).
- **6 GHz** → **PSC** (Preferred Scanning Channels): `5/21/37/…/229`.

## Survey over time

Channel congestion is time‑of‑day dependent — the channel that looks clean during a
lunchtime scan may be slammed at 9 pm. To plan on real data:

```sh
wifiscan --log ~/wifi-survey.jsonl          # leave the TUI running; every scan appends
wifiscan --once --log ~/wifi-survey.jsonl   # or cron a one-shot every 15 min
wifiscan --report ~/wifi-survey.jsonl       # then aggregate
```

The report shows, per band, the cleanest candidate for **each hour of day** with its
average interference level, and an **all‑day pick** — the channel whose *worst* hour
is least bad (minimax), i.e. the safe set‑and‑forget choice:

```
▎ 5 GHz  (non-DFS)
   08:00  ch 149    clean  (12 scans)
   13:00  ch 149   -78dBm  (10 scans)
   21:00  ch 40    -71dBm  (14 scans)
  all-day pick: ch 149  (worst hour -78dBm)
```

Each log line is one JSON object (`ts` epoch seconds + the networks seen), so the
file is also easy to post‑process with `jq`.

## JSON output

`wifiscan --json` prints a pretty array, sorted by signal power (strongest first);
object keys are alphabetised. `noise` and `snr` are present only when macOS actually
measured them, and `utilization` (QBSS airtime, 0…1) only when the AP broadcasts it
(otherwise omitted):

```jsonc
[
  {
    "band": "2.4 GHz",
    "channel": 6,
    "hidden": false,
    "rssi": -34,
    "security": "WPA2/3",
    "ssid": "home-router",
    "widthMHz": 20
  },
  {
    "band": "5 GHz",
    "channel": 161,
    "hidden": false,
    "noise": -94,
    "rssi": -45,
    "security": "WPA2/3",
    "snr": 49,
    "ssid": "home-router-5G",
    "widthMHz": 80
  }
]
```

Example — busiest 2.4 GHz channels:

```sh
wifiscan --json | jq -r '.[] | select(.band=="2.4 GHz") | "\(.channel)\t\(.ssid)"' | sort -n
```

## How it reveals SSIDs (the macOS‑26 catch)

This was the genuinely hard part. On recent macOS, CoreWLAN redacts SSIDs unless
**two** conditions both hold:

1. The app is **authorized for Location Services** (the one‑time grant above), **and**
2. The scan runs in a process launched as a real **LaunchServices app session** —
   *not* a binary spawned directly by a shell. A shell‑child process gets masked
   names **even when Location is authorized**. (This is why "wrap it in a GUI app"
   is the usual advice, and why Apple's own tools are unaffected.)

So `wifiscan` runs the actual scan in a **persistent helper instance of itself
launched via `open`** — a real LaunchServices app session:

```
open -n -g -j wifiscan.app --args --scan-daemon <control-dir>
```

`-n` new instance · `-g` don't foreground · `-j` launch hidden. The helper engages
Location **once**, then stays alive and serves each scan request over a small
atomic‑file protocol in `<control-dir>`, writing results back as JSON. The
front‑end heart‑beats the helper, so it self‑exits if the TUI quits or crashes.
Because the helper persists, refreshes after the first avoid both the process spawn
and the Location settle and are near‑instant. **No Apple Developer account and no
special entitlement are required** — only the Location grant. The full investigation
is in the commit history.

## Architecture

```
            you ── type `wifiscan` (or double-click the .app)
             │
             ▼
   ┌──────────────────────┐   scan request   ┌───────────────────────────┐
   │  TUI front-end        │ ───────────────▶ │  persistent helper         │
   │  (your terminal)      │  (file protocol) │  --scan-daemon (via open)  │
   │  render · keys · sort │ ◀─────────────── │  Location (once) + CoreWLAN │
   └──────────────────────┘   JSON result     └───────────────────────────┘
        launched once via `open`, kept alive          │
        heartbeat → self-exits when the TUI quits      ▼
                                              CWWiFiClient.scanForNetworks
```

- **Front‑end** (`wifiscan` in your terminal): raw‑mode ANSI TUI — rendering, input,
  sorting, the channel map and recommendations. It does **not** need Location.
- **Helper** (`wifiscan --scan-daemon`, reached only via `open`): a long‑lived
  LaunchServices app session that engages Location once and serves each scan over a
  file protocol so SSIDs are visible. Subsequent scans skip both the process spawn
  and the Location settle, so refreshes after the first are near‑instant.
- **Double‑click**: when launched without a TTY (Finder / Spotlight / Dock), the app
  reopens itself in your terminal so the TUI has somewhere to draw. It picks the first
  installed of **Ghostty** (via `open … --args -e`), **iTerm**, then **Terminal**
  (the AppleScript‑driven fallbacks).

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| All SSIDs show `‹hidden›` | Location Services not enabled for **wifiscan**. Enable it in System Settings → Privacy & Security → Location Services, then rerun. Check with `wifiscan --diag`. |
| SSIDs were working, broke after `make` | Ad‑hoc identity changed on rebuild → grant lost. Re‑enable **wifiscan** in Location Services, or use a [stable signing cert](#keep-the-grant-across-rebuilds-optional). |
| `wifiscan --diag` shows `SSIDs visible: 0/N` | Same as above — permission. The metadata (power/channel) still works. |
| First scan takes a few seconds | Expected — the first scan launches the persistent helper and settles Location once. Subsequent refreshes reuse it and are near‑instant. |
| Double‑click prompts "wifiscan wants to control Terminal" (or iTerm) | One‑time macOS Automation prompt — click **OK**; it won't ask again. |
| `Wi‑Fi is powered off` | Turn Wi‑Fi on; the radio must be up to scan. |
| `command not found: wifiscan` | `~/.bin` isn't on your `PATH` — see [Install](#install). |

## Known macOS limitations

- **SNR shows `—` for most networks.** macOS only measures the noise floor on the
  channel your radio is currently tuned to, so neighbouring APs report noise as 0.
  RSSI + congestion are the reliable planning signals; SNR is meaningful only for
  your connected channel.
- **No BSSID or country code.** Both are gated behind Apple‑*private* entitlements
  (`com.apple.private.corewifi.bssid` / `.countrycode`) carried only by `airportd`
  and Apple's own tools (Wireless Diagnostics, `wdutil`) — a third‑party binary
  always gets `nil`, so `wifiscan` doesn't model them. Not needed for channel
  planning.

## Project layout

```
Sources/wifiscan/Core.swift   pure logic — channel plan · bonding · congestion · sorting · text layout
Sources/wifiscan/main.swift   CoreWLAN/CoreLocation · TUI · out-of-process scan helper · entrypoint
Tests/CoreTests.swift         dependency-free unit tests for Core (`make test`, 100% covered)
scripts/check-coverage.sh     coverage gate — fails unless Core.swift is 100% region+line covered
.github/workflows/ci.yml      GitHub Actions: build + test + coverage gate on every push/PR
Info.plist                    app-bundle metadata + Location-Services usage string
Makefile                      `make` → signed wifiscan.app in ~/Applications + launcher; `make test` / `make coverage`
Package.swift                 SwiftPM manifest (for editors/tooling; `make` uses swiftc)
Makefile.local                optional, git-ignored: machine-local SIGN identity
```

No third‑party dependencies — just the system **CoreWLAN**, **CoreLocation** and
**Foundation** frameworks.

## Development

```sh
make                       # build + sign + install (≡ make install)
make test                  # run the core unit tests (no Xcode/XCTest needed — CLT only)
make coverage              # run tests under llvm-cov; fails unless Core.swift is 100% covered
swiftc Sources/wifiscan/Core.swift Sources/wifiscan/main.swift -o /tmp/wifiscan \
    -framework CoreWLAN -framework CoreLocation     # quick type-check / compile
wifiscan --diag            # verify scanning + permission
```

Two files: **`Core.swift`** holds the pure, framework‑free logic (channel plan,
bonding model, congestion scoring, sorting, text layout, and terminal‑escape
sanitization of hostile SSIDs) and is unit‑tested standalone via `make test`;
**`main.swift`** holds `Scanner` (CoreWLAN wrapper),
`HelperClient` / `ScanDaemon` (the persistent out‑of‑process scan), and the
raw‑mode TUI (`enterRaw` / `draw` / `runInteractive`).

`Core.swift` is held at **100% region + line coverage** — `make coverage` (and CI,
on every push/PR) re‑runs the tests under `llvm-cov` and `scripts/check-coverage.sh`
fails the build on any uncovered line. The split is deliberate: all branchy logic
lives in `Core.swift` so it's covered without the system frameworks, while
`main.swift` is kept to thin, framework‑bound plumbing.

## License

MIT — see [`LICENSE`](LICENSE). Copyright © 2026 Lucas Daddiego.
