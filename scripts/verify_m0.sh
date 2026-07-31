#!/bin/bash
# M0 一键回归:构建 → 内核冒烟 → 截图矩阵(双跑确定性)→ 探针 → 打包链
# 全绿输出 M0-GREEN;任何失败立即非零退出。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

BIN=".build/debug/YeTerm"
OUT="artifacts/verify"
mkdir -p "$OUT"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "构建"
swift build

step "内核冒烟(--smoke-term)"
SMOKE=$("$BIN" --smoke-term)
echo "$SMOKE" | grep -q "SMOKE-PASS"
echo "$SMOKE" | grep -q "ch='你' width=2"
echo "smoke ✓"

step "截图矩阵(字体 × 效果 × 尺寸,双跑字节一致)"
fonts=("Menlo" "Ark Pixel 12px Mono zh_cn")
sizes=("80 24" "132 40")
for font in "${fonts[@]}"; do
  for size in "${sizes[@]}"; do
    set -- $size; cols=$1; rows=$2
    for fx in off passthrough crt; do
      tag="${font}_${fx}_${cols}x${rows}"
      a="$OUT/${tag}_a.png"; b="$OUT/${tag}_b.png"
      "$BIN" --render-demo "$a" --cols "$cols" --rows "$rows" --font "$font" --effects "$fx" --time 0 >/dev/null
      "$BIN" --render-demo "$b" --cols "$cols" --rows "$rows" --font "$font" --effects "$fx" --time 0 >/dev/null
      cmp -s "$a" "$b" || { echo "✗ 双跑不一致: $tag"; exit 1; }
      echo "  ✓ $tag ($(sips -g pixelWidth "$a" | awk '/pixelWidth/{print $2}')px)"
    done
    # passthrough 必须与 off 逐像素一致
    "$BIN" --render-demo "$OUT/tmp_cmp.png" --cols "$cols" --rows "$rows" --font "$font" \
      --effects passthrough --compare-with "$OUT/${font}_off_${cols}x${rows}_a.png" --tolerance 0 >/dev/null
    echo "  ✓ ${font} ${cols}x${rows} passthrough≡off(tolerance 0)"
  done
done

step "v1.4 辉光风格 / 发光模型(四组合互异 + 双跑确定 + 缺省=旧路径)"
# 两项可选风格的回归。三条断言:①风格真的进了着色器(四组合两两不同);②每种风格双跑逐字节一致;
# ③**缺省值(bloomStyle=0/emissiveModel=0)必须与不带这两个字段的配置逐像素相同**
#   —— 第③条是最有价值的一条:新特性不许动到老路径。
V4BASE='"version":3,"crtEffectsEnabled":true,"backgroundColor":"#000000","fontColor":"#33ff66","bloom":0.7,"chromaColor":0.4,"brightness":0.5,"contrast":0.8,"saturationColor":0.2,"screenCurvature":0.2,"rasterization":1,"ambientLight":0.2,"margin":0.3,"frameMargin":0.1'
printf '{%s}\n' "$V4BASE" > "$OUT/v4_absent.json"          # 完全不含新字段(模拟旧配置档)
for bs in 0 1; do for em in 0 1; do
  printf '{%s,"bloomStyle":%s,"emissiveModel":%s}\n' "$V4BASE" "$bs" "$em" > "$OUT/v4_b${bs}e${em}.json"
  for run in a b; do
    "$BIN" --render-demo "$OUT/v4_b${bs}e${em}_$run.png" --cols 80 --rows 24 --font Menlo \
      --effects crt --time 0 --config "$OUT/v4_b${bs}e${em}.json" >/dev/null
  done
  cmp -s "$OUT/v4_b${bs}e${em}_a.png" "$OUT/v4_b${bs}e${em}_b.png" \
    || { echo "✗ 双跑不一致: bloomStyle=$bs emissiveModel=$em"; exit 1; }
done; done
"$BIN" --render-demo "$OUT/v4_absent.png" --cols 80 --rows 24 --font Menlo \
  --effects crt --time 0 --config "$OUT/v4_absent.json" >/dev/null
cmp -s "$OUT/v4_absent.png" "$OUT/v4_b0e0_a.png" \
  || { echo "✗ 缺省值与「字段不存在」不等价 —— 新特性动到了老路径"; exit 1; }
echo "  ✓ 缺省 ≡ 旧配置档(逐像素)"
for pair in "b0e0 b1e0" "b0e0 b0e1" "b0e0 b1e1" "b1e0 b0e1" "b1e0 b1e1" "b0e1 b1e1"; do
  set -- $pair
  cmp -s "$OUT/v4_${1}_a.png" "$OUT/v4_${2}_a.png" \
    && { echo "✗ $1 与 $2 出图相同 —— 风格未生效"; exit 1; }
done
echo "  ✓ 四组合两两互异、各自双跑确定"
# 白热化(v1.4「文字发光」拆分的自身那一半):缺省关必须与「字段不存在」等价;
# 开了必须真的改变出图;且双跑确定。
printf '{%s,"overdrive":0.85,"overdriveKnee":0.20}\n' "$V4BASE" > "$OUT/v4_od.json"
printf '{%s,"overdrive":0}\n' "$V4BASE" > "$OUT/v4_od0.json"
for run in a b; do
  "$BIN" --render-demo "$OUT/v4_od_$run.png" --cols 80 --rows 24 --font Menlo \
    --effects crt --time 0 --config "$OUT/v4_od.json" >/dev/null
done
cmp -s "$OUT/v4_od_a.png" "$OUT/v4_od_b.png" || { echo "✗ 白热化双跑不一致"; exit 1; }
cmp -s "$OUT/v4_od_a.png" "$OUT/v4_b0e0_a.png" && { echo "✗ 白热化未生效(与关闭时同图)"; exit 1; }
"$BIN" --render-demo "$OUT/v4_od0.png" --cols 80 --rows 24 --font Menlo \
  --effects crt --time 0 --config "$OUT/v4_od0.json" >/dev/null
cmp -s "$OUT/v4_od0.png" "$OUT/v4_b0e0_a.png" \
  || { echo "✗ overdrive=0 与「字段不存在」不等价"; exit 1; }
echo "  ✓ 白热化:开则改变出图、关则等价于字段不存在、双跑确定"

step "最险假设探针(--probe-draw-off)"
"$BIN" --probe-draw-off | grep -q "PROBE-PASS"
echo "probe ✓"

step "打包链(make_app.sh + app 内资源验证)"
bash scripts/make_app.sh >/dev/null
./dist/YeTerm.app/Contents/MacOS/YeTerm --smoke-term | grep -q "SMOKE-PASS"
./dist/YeTerm.app/Contents/MacOS/YeTerm --render-demo "$OUT/app_crt.png" --cols 40 --rows 12 --effects crt --time 0 >/dev/null
codesign --verify --strict dist/YeTerm.app
file dist/YeTerm.app/Contents/MacOS/YeTerm | grep -q arm64
# 本地网络权限声明防丢(2026-07-30 事故:缺这条 → 内网 ssh 全报 No route to host)
plutil -p dist/YeTerm.app/Contents/Info.plist | grep -q "NSLocalNetworkUsageDescription"
echo "app ✓"

rm -f "$OUT"/tmp_cmp.png
printf '\n\033[1;32mM0-GREEN\033[0m\n'
