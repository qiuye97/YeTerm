#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# 终端吞吐横向跑分 —— 在**每个要对比的终端窗口里**各跑一次,最后 --report 出表。
#
# ⚠️ 注意它和 verify_m0.sh 的本质区别:verify 是无人值守的回归,
#    这个**必须人工在真实终端窗口里跑** —— 因为它测的正是「宿主终端」本身。
#    所以它不进 verify_m0.sh(在 CI/后台跑出来的数字没有意义)。
#
# 用法:
#   bash scripts/bench.sh                    # 在当前终端跑(自动识别是哪个终端)
#   bash scripts/bench.sh --label "自定义名"  # 手动指定名字
#   bash scripts/bench.sh --report           # 合并所有结果,打印对比表
#   bash scripts/bench.sh --list             # 看已经测过哪些
#   bash scripts/bench.sh --clean            # 清空重来
#
# 环境变量:
#   BENCH_SCALE=0.3   负载规模系数(默认 1.0)。终端太慢跑不动时调小,
#                     但**所有终端必须用同一个值**,否则数字不可比。
#   BENCH_REPEAT=3    每个场景跑几次取中位数(默认 3)。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v python3 >/dev/null 2>&1; then
    echo "需要 python3(只用标准库,不装任何包)" >&2
    exit 1
fi

exec python3 scripts/bench_run.py "$@"
