# Changelog

All notable changes to YeTerm.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/).

---

## [1.1.0] — 2026-08-03

### CRT rendering

- **Background images now work in CRT mode**, not only in plain terminal mode.
  The picture replaces the "unlit screen" term of the phosphor colouring
  formula rather than being composited into the content texture, which means
  glowing text always keeps its own colour and can never be washed out by a
  bright image, and the picture is never subject to overdrive or persistence
  smear. It bulges with the screen curvature, picks up the scanlines, and is
  clipped by the bezel — it reads as something displayed behind the glass
  rather than a sheet of paper taped to the front.
- Optional **phosphor tinting** for that background image: off (default) keeps
  the picture's own colours, on renders the whole picture in the phosphor
  colour, as if this old monitor were displaying it.
- The 21 real-device restoration themes in the "Classic CRT" preset group take
  no background image by design — the same reasoning as their locked CRT
  effects: a wallpaper behind the screen would stop them being that machine.

## [1.0.0] — 2026-07-31

First public release.

### The three things this exists to fix

- **arm64 native.** No Rosetta, no translation layer.
- **Any monospace font × CJK × every effect.** CRT effects are a full-screen
  post-process on a rendered text texture, completely decoupled from font
  metrics — so scanlines, the pixel grid and subpixel rasterization all work with
  any font, including CJK ones, with correct column alignment for full-width
  characters.
- **Multi-window, tabs and split panes.**

### CRT rendering

- Scanlines / pixel grid / subpixel rasterization, screen curvature, bloom,
  phosphor persistence, static noise, flicker, horizontal sync loss, RGB
  fringing, jitter, moving scan line, and a bezel with ambient reflection.
- **Text glow split into two orthogonal controls.** "The stroke itself goes
  white" (overdrive — a zero-radius per-pixel transfer function) and "it lights
  up its surroundings" (bloom) are physically unrelated, so they're separate
  knobs. Overdrive is calibrated against the saturation curve of a photograph of
  a real VT220: knee 0.20, strength 0.85, mean squared error 0.035 against the
  photo versus 0.376 with it off.
- Selectable bloom style (energy-preserving Gaussian or halation), bloom shape
  (single Gaussian or tight core + long tail) and emission model.
- Power-on / power-off CRT animations, a BIOS-style power-on self test, and a
  channel-switch flash when changing themes.
- Overdrive is disabled automatically on light-background themes, judged by
  luminance rather than by preset name — the effect's premise is that the bright
  pixels are the text, which inverts on black-on-white themes.

### Presets

43 built-in presets. 21 recreate specific hardware, each tuned to what that
machine physically did — the Tektronix 4014 was a storage tube, so its
persistence is pinned to maximum; the IBM 5151's P39 phosphor drags a green
trail. 22 are classic color schemes (Solarized, Dracula, Nord, Gruvbox, Tokyo
Night, Catppuccin, Monokai and others) shipping their official ANSI tables.

### Terminal

- Plain mode (⌘E) turns every effect off, with its own independent color system
- Command navigation via OSC 133, search, ⌘-click on links and file paths
  (including `path:line` jumps into your editor), paste protection
- Inline images (iTerm2 and Kitty protocols), rendered through the CRT pipeline
- Baud rate limiting, 15 steps from 110 bps, travelling with the preset
- Session restore, screenshot and GIF export, Notification Center integration
- SSH host list with passwords in the system Keychain, automatic fingerprint
  confirmation, and automatic algorithm downgrade for old devices
- Prompt themes — four dependency-free retro prompts plus curated oh-my-zsh
  themes, hot-swappable without disturbing what you're typing

### Interface

- Bilingual (English / 简体中文), switchable live without a restart. Chinese is
  the source language and the default; untranslated strings fall back to Chinese
  rather than showing blanks.
- Settings window using the system Liquid Glass materials on macOS 26, degrading
  to frosted materials on earlier versions

### Performance

Roughly 3.3× the throughput of cool-retro-term and 2× Terminal.app on a
terminal-agnostic benchmark (`scripts/bench.sh`). Enabling the CRT effects costs
essentially nothing — the bottleneck is VT parsing, not the shaders.

CJK parsing uses a [SwiftTerm fork](https://github.com/qiuye97/SwiftTerm) with a
multi-byte fast path; upstream pays a heap allocation, a UTF-8 decode and several
ICU property lookups per character, which made CJK 20.6× slower than ASCII
instead of 3.4×.

### Requirements

macOS 15 or later, Apple Silicon. Built against the macOS 26 SDK — see the build
notes in the README for why both matter.

[1.0.0]: https://github.com/qiuye97/YeTerm/releases/tag/v1.0.0
