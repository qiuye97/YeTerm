# Contributing to YeTerm

Thanks for looking. A few things worth knowing before you spend time on a change.

**Issues are welcome even if you don't want to write code.** Bug reports,
"this looks wrong on my hardware" with a photo, or "your license reasoning about
X is mistaken" are all genuinely useful — see [the note at the end of the
README](README.md#a-note-since-this-is-my-first-time-open-sourcing-anything).

Discussion in English or Chinese, whichever you prefer.

## Getting set up

Requires **Apple Silicon**, and an Xcode with the **macOS 26 SDK** (the build
targets macOS 15 but links against SDK 26 — see the build notes in the README).

```bash
swift build
swift run YeTerm

bash scripts/verify_m0.sh     # full regression; must end with M0-GREEN
```

If your Xcode isn't the default toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

## The self-test suite

This project is unusual in how much it leans on automated self-testing, because
it was written almost entirely by an LLM and needed a way to catch regressions
that a human reviewer wouldn't spot. Please use it.

| Command | What it does |
|---|---|
| `bash scripts/verify_m0.sh` | Full regression. Build → kernel smoke → screenshot matrix (with double-run determinism checks) → probes → packaging. |
| `--render-demo out.png` | Offscreen render harness. `--compare-with ref.png --tolerance 0` does pixel-exact comparison. |
| `--probe-settings <prefix>` | Instantiates the settings window offscreen, screenshots every page, asserts each renders non-blank, and checks ~70 config/i18n invariants. |
| `--auto-drive <prefix>` | Synthesizes real keyboard events through 28 scenarios / 75 steps against a real shell. |
| `--smoke-term` | Headless terminal kernel smoke test (CJK width, attributes). |
| `--perf-probe` | Layered performance probe (VT parsing vs. row building). |
| `bash scripts/bench.sh` | Cross-terminal throughput benchmark. **Must be run by hand inside each terminal window** — it measures the host terminal, so numbers from CI are meaningless. |

**If you change rendering, prove it with pixels.** The convention here is to
build a reference version in a `git worktree` at the previous commit, render the
same scene from both, and compare. "Looks the same to me" has been wrong enough
times in this project that it isn't accepted as evidence.

## Things that will break if you're not careful

These are all real bugs that happened. They're listed because they're not
obvious from reading the code.

**Effects must never depend on font metrics.** The entire reason this project
exists is that CRT effects are a full-screen post-process on a text texture,
decoupled from the font. Any change that makes an effect consult font metadata,
or that restricts the font list based on rasterization mode, breaks the one
thing YeTerm does that cool-retro-term can't.

**Don't translate identifiers.** Preset names, `SettingsSection` raw values, the
marker written into `~/.zshrc`, and anything a menu delegate dispatches on are
identifiers, not display text. Wrap them at the point of display instead
(`Presets.displayName(_:)`, `SettingsSection.title`, `NSMenuItem.representedObject`).

**Don't put `L()` inside a `static let`.** Swift static constants are computed
once and cached forever, which freezes the translation at whatever language was
active at initialization. Use a computed `static var`, or translate at the
display site.

**Use `Lf("… %@ …", x)`, not `L("…\(x)…")`.** String interpolation happens before
the lookup, so an interpolated string can never match the translation table — it
silently falls back to Chinese.

**Color discipline: sRGB encoded values all the way through.** Textures and
drawables use `.bgra8Unorm`, never the `_srgb` variants. The ported GLSL does its
math on gamma-encoded values; linearizing changes the meaning of every constant
carried over from the original.

**All main thread.** SwiftTerm's types aren't `Sendable`.

## Code style

The comments in this codebase are deliberately dense, and in two distinct
registers. Please preserve both if you touch a file:

1. **Engineering comments** — architectural constraints, porting research,
   post-mortems on things that went wrong. These exist so nobody re-derives a
   conclusion that was already paid for.
2. **Teaching comments** — this codebase doubles as the author's macOS learning
   material. Each source file opens with a `📖 初学者导读` section (what this file
   does, analogies to Java/web concepts, syntax highlights), and inline `// 【学】`
   comments explain Swift and macOS concepts in plain language.

Comments are in Chinese. That's a deliberate choice — it's the author's first
language and the source of truth for the project's own documentation. Code
identifiers are English.

## Commit messages

Written in Chinese, and closer to a short post-mortem than a one-liner: what
changed, **why**, what was tried and rejected, and how it was verified. If you
ruled an approach out, say so — that's often the most valuable line in the commit,
because it stops the next person re-deriving it.

## License

YeTerm is GPL-3.0-or-later (inherited from cool-retro-term's shaders, not chosen).
By contributing you agree your contributions are licensed the same way.

If you're adding a bundled asset — a font, a texture, anything — its license must
permit redistribution inside a GPL-3 application, and the full license text has to
be added under the relevant `LICENSES/` directory and itemized in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). One font was already removed
from this project at release time for failing that test; please check before
adding rather than after.
