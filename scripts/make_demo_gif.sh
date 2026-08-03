#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# 录制 README / Release 里那张演示动图,一条命令到底:
#   ① YeTerm --demo-gif 开真实窗口 + 真实 shell,按脚本演一遍(见 DemoGIF.swift);
#   ② ffmpeg 转码压缩 —— 这一步不是可选项,**原始 GIF 有 13 MB**。
#
# 为什么原始文件那么大:CRT 的雪花噪点和闪烁让**每一帧的每个像素都在变**,
# GIF 赖以生存的帧间差分彻底失效。实测(25 秒素材):
#   原始 12fps 840px ················ 13.3 MB
#   只调色板优化(128 色) ············ 13.6 MB ← 反而更大
#   + 关抖动 ························ 12.1 MB
#   + 降到 8fps ······················ 8.2 MB
#   + 时间降噪 hqdn3d ················ 5.8 MB
# 所以配方是「降帧 + 关抖动 + 时间降噪」三样一起上。时间降噪专吃随机噪点,
# 文字笔画和扫描线基本不动 —— 是这里性价比最高的一刀。
#
# ⚠️ 录制期间会**占用屏幕**弹出一个真实窗口(约 25 秒),期间别去点它。
#
# 用法: bash scripts/make_demo_gif.sh [输出路径]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

OUT="${1:-assets/screenshots/crt_live.gif}"
RAW="$(mktemp -d)/raw.gif"
trap 'rm -rf "$(dirname "$RAW")"' EXIT

command -v ffmpeg >/dev/null || { echo "需要 ffmpeg(brew install ffmpeg)" >&2; exit 1; }

echo "==> 构建"
swift build

echo "==> 录制(真实窗口会弹出来演约 25 秒,别去动它)"
# 参数是实测调出来的,改之前先读这几条:
# · 60×26 / 字号 16 —— 点阵字体的字符格接近正方形,列数一多画面就成细长条;
#   而且画面越大,每帧离屏渲染越慢,会把主线程占满(见下)。
# · 限速 4800 而不是更慢的 2400 —— 录制期间每帧都要全屏离屏渲染 + 编 PNG,
#   主线程被占掉大半,限速器的吐字节奏跟着被挤慢,输出越积越多。实测 2400 时
#   演示跑不完 30 秒上限就被截断(画面永远停在"命令打了一半"),4800 刚好跑完
#   且仍看得出逐字吐字。想更慢的话得同时把画面调小或把演示脚本缩短。
.build/debug/YeTerm --demo-gif "$RAW" --preset "IBM 5151" \
  --demo-cols 60 --demo-rows 26 --font-size 16 --demo-rate 4800

echo
echo "==> 压缩(降帧 10fps + 关抖动 + 时间降噪)"
ffmpeg -y -loglevel error -i "$RAW" \
  -vf "fps=10,hqdn3d=6:4:9:6,scale=760:-1:flags=lanczos,split[a][b];\
[a]palettegen=max_colors=96:stats_mode=diff[p];\
[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  -loop 0 "$OUT"

echo
printf "==> 产物 %s  原始 %.1f MB → 成品 %.1f MB\n" "$OUT" \
  "$(echo "scale=2; $(stat -f%z "$RAW")/1048576" | bc)" \
  "$(echo "scale=2; $(stat -f%z "$OUT")/1048576" | bc)"
