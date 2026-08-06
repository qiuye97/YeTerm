#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# 图标全量输出(2026-08-06,起因「p10k 图标 󰜷 U+F0737 空白」排查):
# 在终端里把 Nerd Fonts 全部官方图标区间逐码位打印成带标尺的网格,
# 方便肉眼巡检哪些图标显示异常(空白/豆腐块/错位),并按行标签+列号
# 直接读出出问题字形的码位。
#
# 用法:
#   python3 scripts/dump_icons.py              # 全部区间(约 600 行,可滚回)
#   python3 scripts/dump_icons.py md pl        # 只打指定组(--list 看组名)
#   python3 scripts/dump_icons.py F0700-F0760  # 任意十六进制码位区间
#   python3 scripts/dump_icons.py --list       # 列出全部组名与区间
#
# 判读提示:
#   · 空白格有两种可能 —— ①当前字体本身没有该字形(对照 nerdfonts.com/cheat-sheet
#     或换 iTerm2/Terminal.app 同屏对比可分辨);②渲染链丢字(YeTerm 侧的 bug)。
#   · 2026-08-06 修复前,第 15 平面(U+F0001 起的 md 组)在 YeTerm 里**整组空白**,
#     根因是渲染器用了 SwiftTerm 无侧表的 CharData.getCharacter()。
#   · 建议配合等宽 Nerd 字体(JetBrainsMono NF / Maple Mono NF 等)使用;
#     非 Nerd 字体大面积空白属正常(字形真的不存在)。
# ─────────────────────────────────────────────────────────────────────────────
import sys

# Nerd Fonts v3 官方字形集(nerdfonts.com wiki「Glyph Sets」页整理;
# 区间按码位打印,中间的未分配空洞会显示为空白 —— 属字体层面的正常空白)
GROUPS = [
    ("power", "IEC 电源符号",            [(0x23FB, 0x23FE), (0x2B58, 0x2B58)]),
    ("oct",   "Octicons(GitHub)",        [(0x2665, 0x2665), (0x26A1, 0x26A1), (0xF400, 0xF532)]),
    ("pom",   "Pomicons",                [(0xE000, 0xE00A)]),
    ("pl",    "Powerline + 扩展",        [(0xE0A0, 0xE0A3), (0xE0B0, 0xE0D7)]),
    ("fae",   "Font Awesome Extension",  [(0xE200, 0xE2A9)]),
    ("wea",   "Weather 天气",            [(0xE300, 0xE3E3)]),
    ("seti",  "Seti-UI + Custom",        [(0xE5FA, 0xE6B7)]),
    ("dev",   "Devicons",                [(0xE700, 0xE8EF)]),
    ("codi",  "Codicons(VS Code)",       [(0xEA60, 0xEC1E)]),
    ("fa",    "Font Awesome",            [(0xED00, 0xF2FF)]),
    ("logo",  "Font Logos(发行版)",      [(0xF300, 0xF381)]),
    ("md",    "Material Design(第 15 平面)", [(0xF0001, 0xF1AF0)]),
]

PER_ROW = 16

def print_range(lo, hi):
    # 行起点对齐到 16,标尺让「行标签 + 列号」直接拼出码位
    start = lo - (lo % PER_ROW)
    print("        " + " ".join(f"{i:X}" for i in range(PER_ROW)))
    for row in range(start, hi + 1, PER_ROW):
        cells = []
        for cp in range(row, row + PER_ROW):
            cells.append(chr(cp) if lo <= cp <= hi else " ")
        print(f"U+{row:05X} " + " ".join(cells))

def main():
    args = [a for a in sys.argv[1:]]
    if "--list" in args:
        for key, name, ranges in GROUPS:
            span = ", ".join(f"U+{a:04X}–U+{b:04X}" if a != b else f"U+{a:04X}" for a, b in ranges)
            print(f"{key:6} {name:24} {span}")
        return

    # 自定义区间(如 F0700-F0760)
    custom = []
    keys = []
    for a in args:
        if "-" in a and all(c in "0123456789abcdefABCDEF-xX+U" for c in a):
            lo, hi = (int(x.replace("U+", "").replace("u+", ""), 16) for x in a.split("-"))
            custom.append((lo, hi))
        else:
            keys.append(a.lower())

    selected = [g for g in GROUPS if not keys or g[0] in keys]
    if keys and not selected and not custom:
        print(f"未知组名 {keys},--list 查看可用组")
        sys.exit(1)

    for lo, hi in custom:
        print(f"\n━━ 自定义区间 U+{lo:04X}–U+{hi:04X}({hi - lo + 1} 个码位)━━")
        print_range(lo, hi)
    if custom and not keys:
        return

    for key, name, ranges in selected:
        total = sum(b - a + 1 for a, b in ranges)
        span = ", ".join(f"U+{a:04X}–U+{b:04X}" if a != b else f"U+{a:04X}" for a, b in ranges)
        print(f"\n━━ {name}[{key}] {span}({total} 个码位)━━")
        for lo, hi in ranges:
            print_range(lo, hi)

if __name__ == "__main__":
    main()
