#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# 打发行包:dist/YeTerm-<版本>.zip
#
# 与 make_app.sh 的区别(打包方式,为了「给别人用」):
#   ① 签名沿用 make_app.sh 的政策:**优先 YeTerm Signing 固定证书**
#      (2026-08-07 用户裁决,同事实测 ad-hoc 每版重弹授权:TCC 隐私授权认
#      签名身份,ad-hoc 每次打包指纹都变,下载方的本地网络等授权版版重来;
#      固定证书对 Gatekeeper 并没有更差 —— 同样没公证、首开都要「仍要打开」
#      一次,但授权跨版本保留)。本脚本早年强制 YETERM_ADHOC=1,53a4c57 改
#      政策时漏改了这里(v1.3.1 资产当时是手工重签替换的),2026-08-10 补上。
#      无证书环境(如同事机器)自动回退 ad-hoc,或 YETERM_ADHOC=1 显式指定。
#   ② 用 `ditto --sequesterRsrc --keepParent` 打包。**别用 `zip -r`** ——
#      那会丢掉扩展属性、破坏 .app 的代码签名,用户解开就是一个签名损坏的包。
#      本脚本打完会解压回来重新验一次签名,确保来回一趟没坏。
#
# ⚠️ 用户下载后仍会被 Gatekeeper 拦(「Apple 无法验证…是否包含恶意软件」)——
#    这不是包坏了,而是没有 Apple Developer Program($99/年)的签名与公证。
#    README 的「First run」一节写了放行方法,Release 说明里也要复述一遍。
#
# 用法: bash scripts/make_release.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="dist/YeTerm.app"

echo "==> 构建并打包(签名政策见 make_app.sh:优先 YeTerm Signing 固定证书)"
bash scripts/make_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/YeTerm-${VERSION}.zip"

echo
echo "==> 打 zip: $ZIP"
rm -f "$ZIP"
# --sequesterRsrc:把扩展属性收进 __MACOSX,解压后能原样还原
# --keepParent   :zip 里保留 YeTerm.app 这一层,解开就是个 .app 而不是一堆散文件
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "==> 验证:解压回来重新验签(确认来回一趟没破坏签名)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
codesign --verify --deep --strict "$TMP/YeTerm.app"
echo "    ✓ 签名完好"
"$TMP/YeTerm.app/Contents/MacOS/YeTerm" --smoke-term | grep -q "SMOKE-PASS"
echo "    ✓ 解压后的包能正常运行"

echo
echo "==> 产物"
printf "    %s  (%.1f MB)\n" "$ZIP" "$(echo "scale=2; $(stat -f%z "$ZIP") / 1048576" | bc)"
echo "    SHA-256:"
shasum -a 256 "$ZIP" | awk '{print "      "$1}'
echo
echo "把上面的 SHA-256 贴进 Release 说明,用户可以用"
echo "  shasum -a 256 YeTerm-${VERSION}.zip"
echo "核对下载是否完整。"
