<div align="center">

# YeTerm

**A native Apple Silicon terminal for macOS that looks like a CRT — and lets you type Chinese on it.**

[![CI](https://github.com/qiuye97/YeTerm/actions/workflows/ci.yml/badge.svg)](https://github.com/qiuye97/YeTerm/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-15%2B-lightgrey)
![Architecture](https://img.shields.io/badge/arch-arm64%20native-success)

[简体中文](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md)

<img src="assets/screenshots/hero.png" width="700" alt="YeTerm running with a green phosphor CRT look, showing mixed Chinese, Japanese, Korean and Latin text">

</div>

---

## Why this exists

I used [**cool-retro-term**](https://github.com/Swordfish90/cool-retro-term) daily and loved it. Two things eventually pushed me to write my own:

**1. Rosetta is going away.** cool-retro-term ships as an x86_64 build and runs on Apple Silicon through Rosetta 2. Apple has been winding Rosetta down. When it finally goes, that binary stops running — and the terminal I'd built my habits around goes with it. YeTerm is **arm64 native**, no translation layer.

**2. I couldn't type Chinese on it.** This is the one that actually hurt. In cool-retro-term, the moment you turn on scanlines or the pixel grid, the font selector locks you to a handful of built-in Latin bitmap fonts. Pick any CJK font and the effects refuse to apply. So you get retro looks *or* Chinese text, never both.

That limitation isn't arbitrary — its rasterizer depends on per-font pixel metrics (`pixelSize` / `fontWidth` / `lineSpacing`) that only the bundled fonts carry. YeTerm takes a different route: **every CRT effect is a full-screen post-process applied to a rendered text texture, completely decoupled from the font.** Text is rasterized normally with whatever font you want, and the effects are layered on top of the resulting texture. The pixel-grid spacing is derived from the current font's actual cell size instead of a lookup table.

So this works, and it's the whole point of the project:

<div align="center">
<img src="assets/screenshots/g3_cjk_scanline.png" width="620" alt="Chinese, Japanese and Korean text in a pixel font, rendered under CRT scanlines with a green phosphor tint">
<br><em>Ark Pixel (a CJK bitmap font) under scanlines + phosphor tint + screen curvature. Column alignment holds for full-width characters.</em>
</div>

A third annoyance, while I was at it: cool-retro-term only opens **one window**. YeTerm has native multi-window, tabs, and split panes.

## What it looks like

<div align="center">
<img src="assets/screenshots/crt_live.gif" width="620" alt="Animated CRT effects: flicker, static noise and a moving scan line">
<br><em>The effects are live — flicker, static, the moving scan line, phosphor persistence.</em>
</div>

**43 built-in presets.** 21 recreate specific hardware, 22 are classic color schemes (Solarized, Dracula, Nord, Gruvbox, Tokyo Night, Catppuccin…).

<div align="center">
<img src="assets/screenshots/presets_grid.png" width="900" alt="Six presets side by side: Default Amber, Apple ][, Commodore 64, DEC VT220, IBM 5151, Tektronix 4014">
</div>

Each hardware preset is tuned to what that machine actually did — the Tektronix 4014 was a *storage tube*, so its image stayed on the phosphor without refreshing, which is why its persistence is pinned to maximum. The IBM 5151 used P39 long-persistence phosphor, so moving text drags a green trail. The Commodore 64's light-purple-on-blue comes from the VIC-II chip.

## Features

- **CRT rendering** — scanlines / pixel grid / subpixel rasterization, screen curvature, bloom, phosphor persistence, static noise, flicker, horizontal sync loss, RGB fringing, jitter, moving scan line, bezel with ambient reflection
- **Text glow, split in two** — "the stroke itself goes white" (overdrive, zero-radius) and "it lights up its surroundings" (bloom) are physically unrelated, so they're separate knobs. Calibrated against photographs of a real VT220.
- **Plain mode** — one keystroke (⌘E) turns all of it off and you get a clean modern terminal, with its own independent color system
- **Any monospace font, any script** — including CJK, in every rasterization mode
- **Multi-window / tabs / split panes** with a glowing divider line
- **Baud rate limiting** — 15 steps from 110 bps up, if you want to watch text crawl onto the screen the way it used to
- **Inline images** (iTerm2 + Kitty protocols) — pictures go through the whole CRT pipeline
- **Command navigation** (OSC 133), search, ⌘-click on links and file paths, paste protection, session restore, screenshot & GIF export
- **SSH host list** with passwords in the system Keychain and automatic algorithm downgrade for old devices
- **Bilingual UI** — English / 简体中文, switchable live without a restart
- **Prompt themes** — four dependency-free retro prompts plus curated oh-my-zsh themes, hot-swappable

## Performance

Retro looks shouldn't cost you a usable terminal. Throughput measured with a terminal-agnostic benchmark (`scripts/bench.sh` — it writes a payload to stdout and times how long the terminal takes to drain the PTY, the same approach vtebench uses):

| Scenario | Ghostty | Terminal.app | **YeTerm** (CRT on) | cool-retro-term |
|---|---|---|---|---|
| Plain scrolling | 0.083s | 0.154s | **0.072s** | 0.283s |
| Dense ANSI color | **0.077s** | 0.296s | 0.158s | 0.441s |
| CJK wide chars | **0.061s** | 0.174s | 0.082s | 0.352s |
| Full-screen redraw | 0.065s | 0.120s | **0.045s** | 0.201s |
| Random cursor jumps | **0.024s** | 0.079s | 0.051s | 0.050s |
| **Total** | **0.311s** | 0.823s | 0.408s | 1.328s |
| **Relative** | **1.00×** | 2.65× | 1.31× | 4.27× |

*100×30 cells, 3 runs, median. Ghostty is faster and I'm not going to pretend otherwise — it's a serious performance-focused terminal. The numbers that matter to me: YeTerm is **3.3× faster than cool-retro-term** and **2× faster than Terminal.app**, and it beats both on CJK by a wide margin.*

Two findings worth calling out:

- **Turning the CRT effects on costs essentially nothing** (0.405s off vs 0.408s on). The bottleneck is VT parsing, not the shaders — which is the whole argument for doing effects as a decoupled post-process.
- **CJK parsing needed a patch.** Upstream SwiftTerm's multi-byte hot path pays a heap allocation, a UTF-8 decoder and several ICU property lookups *per character*, making CJK 20.6× slower than ASCII. YeTerm uses a [fork](https://github.com/qiuye97/SwiftTerm) with a fast path that brings it to 3.4× (`--perf-probe` reproduces this).

## Install

**Requires macOS 15 or later, on Apple Silicon.**

### Download a build

Grab the `.zip` from [Releases](https://github.com/qiuye97/YeTerm/releases), unzip it, and drag `YeTerm.app` into `/Applications`.

> ### ⚠️ macOS will refuse to open it the first time
>
> You'll get *"Apple could not verify 'YeTerm' is free of malware."* **This is expected and it isn't a sign that something is wrong with the download.**
>
> The app *is* signed — but with an ad-hoc signature, not an Apple Developer ID, and it isn't notarized. Both require a $99/year Apple Developer Program membership, which this project doesn't have. macOS treats every app without one the same way.
>
> Two ways past it:
>
> **Through the UI** — try to open the app once and let it fail, then go to **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to the message about YeTerm. Open the app again and confirm. (Recent macOS versions dropped the old Control-click → Open shortcut for unnotarized apps, so this is the path that actually works.)
>
> **Or in a terminal** — strip the download quarantine flag directly:
> ```bash
> xattr -dr com.apple.quarantine /Applications/YeTerm.app
> ```
>
> You only have to do this once.

If you want to check the download arrived intact, each release lists a SHA-256:

```bash
shasum -a 256 YeTerm-1.1.0.zip
```

### Or build from source

No Gatekeeper prompt this way, since you build it locally.

```bash
git clone https://github.com/qiuye97/YeTerm.git
cd YeTerm
swift build -c release
swift run -c release YeTerm
```

To produce an `.app` bundle:

```bash
bash scripts/make_app.sh      # produces dist/YeTerm.app
open dist/YeTerm.app
```

<details>
<summary><strong>Build notes</strong></summary>

- Built with the macOS 26 SDK but deployed to macOS 15. SwiftPM writes the deployment target into *both* the `minos` and `sdk` fields of `LC_BUILD_VERSION`, and macOS 26 decides whether to give an app the Liquid Glass design based on "linked against SDK ≥ 26" — so `make_app.sh` runs `vtool -set-build-version macos 15.0 26.0` to set them independently. You need an Xcode with the macOS 26 SDK for this.
- Metal shaders are compiled at runtime from `.metal` source (`--shader-dir` redirects them for live editing; ⌘R reloads).
- `bash scripts/verify_m0.sh` runs the full regression. It should end with `M0-GREEN`.

</details>

## Configuration

Settings live in `~/Library/Application Support/YeTerm/config.json`, in a format compatible with cool-retro-term's exports. Themes are individual JSON files under `profiles/`.

Every field is documented in [the theme format reference](Sources/YeTermKit/Resources/Docs/主题配置格式.md) (Chinese), which also ships inside the app — Settings → Profiles → "Save to Disk". It's written so you can hand it to an LLM and have it generate a theme for you.

<div align="center">
<img src="assets/screenshots/settings_en.png" width="700" alt="YeTerm settings window, Terminal section, in English">
</div>

## How this was built

**Every line of this project was written by [Claude Code](https://claude.com/claude-code).** I'm a Java/web developer — I don't write Swift, Metal, or AppKit. I acted as the product owner: I decided what to build, tested each build by hand, said "that doesn't look right yet," and made the calls when there was a trade-off. Claude did the engineering.

Eight days of work: 15,448 lines of Swift across 51 files, plus 1,078 lines of Metal shaders.

I'm being upfront about this partly because it's honest and partly because I think the interesting part isn't "an AI wrote it" — it's *what that required*. The things that actually made it work were the boring ones:

- **Verify everything against the source.** The CRT effects are ported from cool-retro-term's GLSL. Every constant was checked against the archived original, and a couple of the design assumptions I'd started from turned out to be wrong — `contrast` and `saturation` never reach the shader at all, for instance; they pre-mix colors on the CPU side.
- **Measure, don't theorize.** Three separate times we implemented a more "physically correct" glow model, and three times a photograph of an actual CRT contradicted it. Real phosphor highlights *do* wash out toward white; the "energy-preserving" model that seemed obviously right looked wrong. The measurements won every time.
- **Build the self-tests.** There's an offscreen render harness that does pixel-exact comparisons, a probe that instantiates the settings window and screenshots every page, and a driver that synthesizes real keyboard events through 75 steps across 28 scenarios. Without those, an AI-written codebase this size would have rotted within days.

## Credits

**[cool-retro-term](https://github.com/Swordfish90/cool-retro-term)** by Filippo Scognamiglio and contributors — the benchmark and the source material. The shaders here are ported from its GLSL, which is why YeTerm is GPL-3. This project isn't trying to replace it; it's trying to keep that look alive on hardware where it can no longer run, with the three limitations above fixed.

**[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** by Miguel de Icaza — the terminal emulation core. Writing a VT100/xterm parser from scratch would have sunk this project.

**[Cathode](https://secretgeometry.com/apps/cathode/)** by Secret Geometry — a beautiful commercial retro terminal. It's what made me realize that "the stroke glowing white" and "the glow lighting up its surroundings" are two unrelated things that deserve separate controls. YeTerm's overdrive parameter came from thinking about that. My respect to its authors.

**Fonts** — Ark Pixel, Terminus, Inconsolata, Hermit, Fixedsys Excelsior, ProggyTiny, ProFont, PxPlus IBM (VileR / int10h), Pet Me and Print Char 21 (Kreative Software), Atari Classic (Mark Simonson), C64 Pro Mono (Style). Every license is reproduced in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and shipped inside the app.

## A note, since this is my first time open-sourcing anything

I built this for myself and I'm publishing it because it might be useful to someone else. I'm not a Swift developer, and there is certainly code in here that will make an experienced macOS engineer wince. Please go easy on me — and if you spot something genuinely wrong, an issue explaining *why* is worth more to me than a polite silence.

**On licensing and attribution:** I've tried hard to get this right — every bundled font's license was checked individually against upstream terms, one font was removed before release because its license doesn't permit redistribution, and the shader provenance is documented file by file. But I'm an amateur at this, and I may have missed something.

**If this project infringes your work — code, fonts, trademarks, anything — please open an issue or email me. I will take it down. No argument, no delay.** I'd rather lose the project than keep something that isn't mine to publish.

## License

Copyright © 2026 [qiuye97](https://github.com/qiuye97).

**GPL-3.0-or-later.** See [LICENSE](LICENSE).

The CRT shaders are derived from cool-retro-term's GPL-3 GLSL, so the license is inherited rather than chosen. Third-party components and their separate licenses are itemized in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
