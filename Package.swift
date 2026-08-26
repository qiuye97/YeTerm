// swift-tools-version: 5.10
// ⚠️ 为什么钉 5.10 而不是 6.0:本机 CLT(macOS 27 beta)的 ManifestAPI 目录里残留了
// 2024-02 的 Swift 5.10 版 private.swiftinterface,遮蔽新接口 → 6.0 专属 API
// (swiftLanguageMode / .macOS(.v15))在清单编译时不可见。用 5.10 兼容面绕过:
//   - tools-version < 6.0 ⇒ 各 target 默认 Swift 5 语言模式(正合需要,SwiftTerm 非并发净)
//   - 平台版本用字符串形式 .macOS("15.0")(自 5.0 起可用)
// 若日后修复 CLT(重装或清掉陈旧 private.swiftinterface),可平滑升回 6.0 写法。
import PackageDescription

let package = Package(
    name: "YeTerm",
    // 部署目标 15(开源前从 26 下调:钉 26 意味着只有装了 macOS 26 的人能跑,
    // 受众几乎为零)。
    //
    // ⚠️ 这里有个 SwiftPM 的坑,改之前必读:macOS 26 按「链接 SDK ≥26」决定
    // 是否给这个 app 启用 Liquid Glass 新设计,而 **SwiftPM 会把部署目标同时
    // 戳进 LC_BUILD_VERSION 的 minos 和 sdk 两个字段** —— 单改这里会让 sdk
    // 也变成 15,于是 macOS 26 把整个 app 按旧 app 兼容渲染,设置页所有系统
    // 控件(滑杆/开关)退回老外观(v1.0 时代实测过的教训)。
    //
    // 解法在 scripts/make_app.sh:打包时用 `vtool -set-build-version macos
    // 15.0 26.0` 把 sdk 字段改回 26 —— minos=15(能在 15 上跑)、sdk=26
    // (Liquid Glass 生效)。两个字段本就该分开,这不是撒谎:我们**确实**是用
    // SDK 26 编译的,只是 SwiftPM 没提供分别设置的入口。
    //
    // 代价:所有 macOS 26 专属 API 现在必须用 #available 保护,否则编译报错
    // (这正是我们要的 —— 编译器替我们把关)。
    platforms: [.macOS("15.0")],
    dependencies: [
        // 终端仿真内核(MIT)。2026-07-30 起改用自家 fork 的 yeterm-perf 分支:
        // 基线 = 上游 v1.15.0 + CJK 解析快路径(上游多字节热路径每字符要付
        // 堆分配数组 + UTF8 解码器 + 多次 ICU 属性查询,CJK 比 ASCII 慢 20.6x;
        // 补丁后 3.3x,详见 fork 的 commit 4e24d2a 与本仓 --perf-probe)。
        // 补丁二(0cf2bec):`queuePendingDisplay` 的合并间隔原本写死 16.67ms(60fps),
        //   把内容更新通知**封顶在 60/s,与显示器刷新率无关** —— 高刷屏上由 PTY 输出
        //   驱动的滚动永远上不了 60fps。改为可由宿主设置的 `updateCoalescingFPS`
        //   (缺省仍 60,行为与上游逐字相同),YeTerm 按 NSScreen.maximumFramesPerSecond 设它。
        // 补丁三(2abc31e):computeFontDimensions 的列宽测量修两处 ——
        //   ①'W' 改经 CTFontGetGlyphsForCharacters 查字形(像素字体常无 post 表
        //   字形名,NSFont.glyph(withName:) 静默返回 .notdef,其 advance 往往是
        //   全宽 em → 格宽翻倍,鼠标命中列 = 实际列的一半,Ark Pixel 首当其冲);
        //   ②物理像素对齐 ceil→round(resolveFont 把 advance 对齐到半逻辑点后,
        //   advance×scale 落在整数 ±1ulp,ceil 会把 +ulp 残差顶成整整一像素,
        //   与图集 round 出的列宽每格漂 1px,选区越拖越偏 —— 用户实测 bug 根因)。
        // revision 钉死保可复现;后续性能定制也走这个 fork,升级上游时先 rebase。
        .package(url: "https://github.com/qiuye97/SwiftTerm.git", revision: "2abc31e9c75d8678adcf3a3ccf8d3961fb635891")
    ],
    targets: [
        // 薄可执行壳:只做 CLI 分发
        .executableTarget(
            name: "YeTerm",
            dependencies: ["YeTermKit"],
            exclude: ["embedded-Info.plist"],
            // 把最小 Info.plist 内嵌进可执行文件(裸二进制也有语言声明,
            // `swift run` 时文件选择器等 AppKit 对话框才会说中文;打包后以
            // .app 的 Contents/Info.plist 为准,内嵌份自动失效)。
            // 【学】-sectcreate 是链接器指令:把一个文件原样塞进产物的指定段;
            //   __TEXT,__info_plist 是 macOS 约定的"单文件程序的 Info.plist
            //   藏身处"。路径相对包根(scripts/ 与手敲构建都从包根跑)。
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/YeTerm/embedded-Info.plist"
            ])]
        ),
        // 全部实现在库里:M2 多窗口与单测都依赖这个结构
        .target(
            name: "YeTermKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [
                // .metal 以纯文本入包(无 Xcode/离线 metal 编译器,运行时 makeLibrary(source:) 编译)
                .copy("Resources/Shaders"),
                .copy("Resources/Textures"),
                .copy("Resources/Fixtures"),
                .copy("Resources/Fonts"),
                .copy("Resources/Tools"),
                .copy("Resources/Docs"),
                // 多语言译文表(.strings 文本,运行时按当前语言加载;见 Localization.swift)
                .copy("Resources/L10n")
            ]
        ),
        .testTarget(
            name: "YeTermKitTests",
            dependencies: ["YeTermKit"]
        )
    ]
)
