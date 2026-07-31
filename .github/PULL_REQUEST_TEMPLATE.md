# What this changes / 这个 PR 改了什么

<!-- One or two sentences. 一两句话说清楚。 -->

## Why / 为什么

<!--
The reasoning matters more than the diff here. If you tried an approach that
didn't work, say so — that's often the most valuable part of the commit.
理由比 diff 重要。如果你试过某个方案没走通,请写出来 —— 那常常是最有价值的部分。
-->

## How it was verified / 怎么验证的

<!-- Tick what applies, and paste the relevant output. 勾选适用项并贴出输出。 -->

- [ ] `bash scripts/verify_m0.sh` ends with `M0-GREEN`
- [ ] `swift run YeTerm --probe-settings /tmp/p` → `SETTINGS-PROBE-PASS`
- [ ] `swift run YeTerm --auto-drive /tmp/a` → `AUTO-DRIVE-DONE`
- [ ] Tested by hand in the real app

**If this touches rendering**, pixel evidence is required — not "looks the same
to me". The convention is to build a reference in a `git worktree` at the base
commit, render the same scene from both, and compare:

```bash
git worktree add /tmp/ref <base-commit> && (cd /tmp/ref && swift build)
/tmp/ref/.build/debug/YeTerm --render-demo /tmp/ref.png --preset "DEC VT220" --effects crt --time 0
swift run YeTerm --render-demo /tmp/new.png --preset "DEC VT220" --effects crt --time 0 \
  --compare-with /tmp/ref.png --tolerance 0
```

<!-- Paste before/after images for anything visual. 观感类改动请贴对比图。 -->

## Checklist

- [ ] No effect now depends on font metrics (this would break the project's whole point)
- [ ] New user-facing strings are wrapped in `L()` / `Lf()` and translated in `Resources/L10n/en.strings`
- [ ] No `L()` inside a `static let`
- [ ] Identifiers (preset names, section IDs, `~/.zshrc` markers) are not translated
- [ ] New files carry both comment tracks (`📖 初学者导读` header + inline `// 【学】`)
- [ ] Any newly bundled asset's license permits redistribution in a GPL-3 app, its
      full text is under the relevant `LICENSES/` directory, and it's listed in
      `THIRD-PARTY-NOTICES.md`
