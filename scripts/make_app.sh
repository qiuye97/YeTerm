#!/bin/bash
# 打包 dist/YeTerm.app(本地自用,ad-hoc 签名,无需公证)
# 用法: bash scripts/make_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 构建需要带 macOS 26 SDK 的工具链(见 README 的构建说明)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

echo "==> release 构建"
swift build -c release

APP="dist/YeTerm.app"
BIN=".build/release/YeTerm"
BUNDLE_SRC="$(dirname "$BIN")/YeTerm_YeTermKit.bundle"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/YeTerm"

# LC_BUILD_VERSION 修正:把 sdk 字段改回 26,minos 保持 15(详见 Package.swift 的
# 长注释)。macOS 26 靠「链接 SDK ≥26」决定要不要给这个 app 上 Liquid Glass,
# 而 SwiftPM 把部署目标同时写进了 minos 和 sdk 两个字段,单靠它做不出
# 「能在 15 上跑 + 在 26 上是新外观」这个组合。
# 【学】vtool 是 Xcode 自带的 Mach-O 小工具,专门改这类"二进制里的元数据"。
#      必须在 codesign **之前**跑 —— 改二进制会让已有签名失效。
echo "==> 修正 LC_BUILD_VERSION(minos 15.0 / sdk 26.0)"
xcrun vtool -set-build-version macos 15.0 26.0 -replace \
    -output "$APP/Contents/MacOS/YeTerm" "$APP/Contents/MacOS/YeTerm" >/dev/null
xcrun vtool -show-build-version "$APP/Contents/MacOS/YeTerm" | grep -E "minos|sdk" | sed 's/^/    /'
# SwiftPM 资源 bundle(Bundle.module 会在 Bundle.main.resourceURL 下找它)
if [ -d "$BUNDLE_SRC" ]; then
  cp -R "$BUNDLE_SRC" "$APP/Contents/Resources/"
else
  echo "!! 资源 bundle 未找到: $BUNDLE_SRC" >&2
  exit 1
fi
# SwiftTerm 自己的资源 bundle(若存在也要带上)
for b in "$(dirname "$BIN")"/SwiftTerm_*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/" && echo "    + $(basename "$b")"
done

# App 图标(assets/AppIcon.icns,由 scripts/make_icon.swift 生成)
if [ -f "assets/AppIcon.icns" ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "    + AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>YeTerm</string>
    <key>CFBundleIdentifier</key><string>com.yeterm.YeTerm</string>
    <!-- 本地化声明:AppKit **自己**生成的文案(标签页右键菜单、输入法候选栏、
         标准「关于」面板等)按 app 声明的语言 + 系统语言挑选。
         DevelopmentRegion = zh-Hans:本项目以中文为源语言,缺翻译一律回落中文。
         Localizations 同时声明 en:英文系统上这些系统文案才会是英文
         (v1.5 开源:受众不再只有作者本人)。
         ⚠️ 这管的只是 **AppKit 自带**的那部分文案;YeTerm 自己的界面语言由
         设置页「界面语言」控制(见 Sources/YeTermKit/Config/Localization.swift)。
         2026-08-06 起两者不再独立:Localization 会把界面语言同步进 app 域的
         AppleLanguages 覆盖项,AppKit 那半边(文件选择器等)也跟着设置走
         (运行中切换要下次启动才生效)。本声明仍是前提 —— app 不声明支持的
         语言,覆盖项写了也白写(裸二进制同理,见 Sources/YeTerm/embedded-Info.plist)。 -->
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>CFBundleName</key><string>YeTerm</string>
    <key>CFBundleDisplayName</key><string>YeTerm</string>
    <key>CFBundleShortVersionString</key><string>1.3.8</string>
    <key>CFBundleVersion</key><string>13</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <!-- 「关于」面板与 Finder 简介里显示的版权行 -->
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 qiuye97. Licensed under GPL-3.0-or-later.</string>
    <!-- 本地网络权限(2026-07-30 用户实测事故:ssh 内网主机报
         "No route to host",而公网正常、别的终端也正常)。macOS 15 起访问
         局域网属隐私权限:没有这个声明键,系统连授权弹窗都不给,直接静默
         拒绝 —— 表现就是 ARP 都不通、ping 全丢包、connectx 返回 EHOSTUNREACH。
         终端里跑的 ssh/curl/ping 都算在宿主 app 名下,所以 Terminal.app
         (早已获授权)能连、YeTerm 不能连。授权后固定证书身份让它长期有效。
         NSBonjourServices:声明后才能解析 .local/mDNS 主机名与浏览局域网服务
         (ssh 到 xxx.local、内网服务发现;按 IP 直连只需上面那条)。 -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>YeTerm 需要访问本地网络,才能让你在终端里 ssh 连接内网主机、访问局域网服务。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ssh._tcp</string>
        <string>_sftp-ssh._tcp</string>
        <string>_http._tcp</string>
    </array>
    <!-- 「能打开文件夹」声明(2026-08-07 用户需求:超级右键/访达右键进入目录)。
         超级右键这类工具对自定义 app 做的是 `open -a YeTerm <目录>`,系统走
         LaunchServices「打开文档」事件投递;声明 public.folder 后 Finder 的
         「打开方式」/拖文件夹到 Dock 图标也一并可用。接收端在
         AppDelegate.application(_:open:) —— 目录进新窗当工作目录。
         Rank=Alternate:能打开,但绝不抢当文件夹的默认打开程序(那是 Finder)。 -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 空 lproj 目录 = 向 NSBundle 声明"本 app 支持这些语言"(配合上面 plist 两键,
# AppKit 框架自身的自动文案才会跟着选)
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/zh_CN.lproj" \
         "$APP/Contents/Resources/en.lproj"

# 签名身份(v1.1 #7):优先用本机自签证书「YeTerm Signing」—— 身份固定,
# TCC 隐私授权不再因重打包漂移反复弹窗;证书不存在(如同事机器)回退 ad-hoc。
# 【学】ad-hoc(--sign -)= 无身份的"匿名签名",每次打包指纹都变,
#      macOS 会把新包当陌生程序;固定证书签名 = 每次都是"同一个人"。
# ⚠️ 发行包政策(2026-08-07 用户裁决,同事实测「每个新版都重弹授权」):
# **release zip 也用 YeTerm Signing 固定证书签**,别再用 ad-hoc ——
# TCC 认签名身份,ad-hoc 每版一变,下载方的本地网络等授权版版重来;
# 固定证书对 Gatekeeper 并没有更差(两者同样是「没公证」,首开都要
# 「仍要打开」一次),但授权从此跨版本保留。
# YETERM_ADHOC=1 保留作逃生口(无证书环境复现构建用),发行流程不要用。
if [ "${YETERM_ADHOC:-0}" = "1" ]; then
    echo "==> ad-hoc 签名(发行包模式)"
    codesign --force --sign - "$APP"
elif security find-identity -p codesigning -v 2>/dev/null | grep -q "YeTerm Signing"; then
    echo "==> 自签证书签名(YeTerm Signing)"
    codesign --force --sign "YeTerm Signing" "$APP"
else
    echo "==> ad-hoc 签名(未找到 YeTerm Signing 证书,身份不固定)"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> 产物检查"
file "$APP/Contents/MacOS/YeTerm"
echo "OK: $APP"
