# Changelog

All notable changes to YeTerm.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/).

---

## [1.3.1] — 2026-08-07

### Fixed

- **Opening a folder from Finder no longer also restores the previous
  session.** Right-clicking a folder into YeTerm (or dragging one onto the
  Dock icon) used to open the folder window *plus* whatever the last session
  had — the restored window read as "a second window that ignored my folder".
  A launch whose reason is "open a document" now shows only the folder window;
  the session archive is untouched and a normal launch still restores it.
  Also covers launchers that start the app first and deliver the folder a beat
  later — that gap used to produce a stray default window.

## [1.3.0] — 2026-08-07

### Added

- **Animated wallpapers: GIF and video backgrounds.** The background image
  picker now accepts GIF, mp4, mov and m4v. The player acts purely as a frame
  source — each frame is fed as a texture into the existing background
  pipeline, so in CRT mode the video bulges with the screen curvature, picks
  up scanlines, and can be phosphor-tinted, exactly like a still image. Video
  is hardware-decoded (AVFoundation, zero-copy into Metal), always muted, and
  loops seamlessly; GIFs are pre-decoded within a memory budget. A frame-rate
  cap (15/30/60 fps, default 30) bounds the on-screen update rate — lower
  saves power — and playback pauses while the window is hidden. All five
  preprocessing effects (frosted glass, pixel-art, darken, mono film) apply
  per-frame.
- **Per-preset wallpapers.** Background image settings now travel with the
  preset instead of being one global value — each preset remembers its own
  image, effect and parameters. A one-time migration cleans up stale wallpaper
  values that old full-snapshot overrides had captured; the wallpaper you
  currently see stays with the preset it's on.
- **Darken level slider** for the darken background effect: 0 = original
  image, 0.5 = the previous fixed look (bit-exact), 1 = black.
- **Unfocused cursor styles.** When keyboard focus leaves the terminal (other
  app, or the search field), the block cursor becomes a hollow outline, the
  underline and bar cursors dim to half strength, and blinking stops — same
  conventions as Terminal.app. An unfocused cursor also no longer feeds the
  phosphor-persistence trail.
- **VaporWave preset** in the Classic Color Schemes group: the canonical
  vaporwave palette (pink `#ff71ce`, cyan `#01cdfe`, mint `#05ffa1`, lavender
  `#b967ff`, cream `#fffb96`) on a faded violet backdrop, with the CJK pixel
  font for that full-width ＡＥＳＴＨＥＴＩＣ. Sister theme to Plasma's
  synthwave.
- **Open a folder in YeTerm from Finder.** Right-click helpers (超级右键 and
  friends), dragging a folder onto the Dock icon, and `open -a YeTerm <dir>`
  all open a new window with the shell already in that directory. Launching
  the app this way replaces the default first window with the folder window.
  A `--cwd <dir>` flag covers argument-style integrations.

## [1.2.1] — 2026-08-06

### Fixed

- **Characters outside the Basic Multilingual Plane rendered as blank cells** —
  most visibly the Nerd Fonts v3 Material Design icons (Plane 15, `U+F0001`
  and up) that powerlevel10k uses, such as the up arrow `󰜷` (U+F0737), and
  all emoji beyond the BMP. SwiftTerm stores such characters (anything needing
  two UTF-16 code units) as an index into a side table rather than as a code
  point; the renderer was decoding cells with the context-free accessor, which
  can't reach that table and falls back to a space — so the cell kept its
  width but drew nothing. All cell decoding now goes through the
  terminal-aware accessor. Old-style BMP icons (Powerline triangles etc.) were
  never affected. Emoji now draw as white silhouettes (the glyph pipeline is a
  monochrome mask by design); color emoji is a separate topic.

### Added

- `scripts/dump_icons.py` — prints every official Nerd Fonts glyph range as a
  ruler-labelled grid, so you can eyeball which icons render and read the code
  point of any cell straight off the row label and column index.

## [1.2.0] — 2026-08-03

### CRT rendering

- **Custom text color in CRT mode.** A third swatch in Settings → Colors sets
  the default foreground — the color of ordinary output that carries no ANSI
  color codes. Until now that color was fixed at pure white and everything came
  out as the phosphor color. Unlike adjusting the phosphor foreground (which,
  at full chroma, multiplies into every color and tints `vim`/`htop` output
  along the way), text color leaves the ANSI palette untouched — matching how
  plain terminal mode has always treated its own text color. The default is
  pure white, which renders pixel-for-pixel as before.
- At low chroma the screen is a monochrome phosphor, so only the *brightness*
  of the chosen text color shows — the hue is absorbed by the phosphor
  tinting. The settings page says so next to the swatch.
- The 21 real-device restoration themes keep their text color locked at pure
  white: white maps to the pure phosphor color after tinting, which their
  researched look depends on. Same product logic as their locked effects and
  background image.

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
