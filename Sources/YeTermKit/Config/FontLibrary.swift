// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 字体管理:注册、枚举、模糊搜索
//
// 这个文件:三件事 ——
//   ① 把打包进 app 的 12 款复古字体注册进"本进程"(CTFontManager,
//     无需安装到系统,app 一退全消失 —— 对用户零污染);
//   ② 枚举系统全部字体族给设置页列表;
//   ③ 模糊搜索:子序列匹配("mpl" 能命中 "Maple Mono"),
//     就是编辑器 ⌘P 文件搜索的那个算法,十行代码的双指针。
//
// 语法看点:
//   `Bundle.module` —— SwiftPM 资源包的入口:Package.swift 里声明的
//     resources 打包后从这取(类比 Java 的 getResourceAsStream)。
//   `static var` + 静态方法 —— 无实例的工具类风格(enum 命名空间同款)。
//   `map(\.family)` —— KeyPath 简写,等于 map { $0.family }
//     (类比 Java 的方法引用 Foo::getFamily)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import CoreText

/// 字体库(M3 设置页):
/// - 启动时把 cool-retro-term 1.2 的 12 款内置复古字体注册进本进程(CTFontManager,
///   进程级作用域,无需安装),它们随即出现在字体枚举与 CTFont 解析里;
/// - 枚举**系统全部已装字体族**(不做等宽过滤 —— G3 红线:可选字体集合不受限);
/// - 模糊搜索(子序列匹配,"mpl" 命中 "Maple Mono")。
enum FontLibrary {
    /// 内置复古字体(family 名以运行时注册结果为准;此表用于展示排序/归类)
    struct RetroFont {
        let file: String        // Resources/Fonts/ 内文件名
        let display: String     // crterm 的展示名(备注来源年代)
    }

    static let retroFonts: [RetroFont] = [
        .init(file: "TerminusTTF-4.46.0.ttf", display: "Terminus (Modern)"),
        .init(file: "ProFontWindows.ttf", display: "Pro Font (Modern)"),
        .init(file: "FSEX301-L2.ttf", display: "Fixedsys Excelsior (Modern)"),
        .init(file: "PetMe.ttf", display: "Commodore PET (1977)"),
        .init(file: "ProggyTiny.ttf", display: "Proggy Tiny (Modern)"),
        .init(file: "PrintChar21.ttf", display: "Apple ][ (1977)"),
        .init(file: "AtariClassic-Regular.ttf", display: "Atari 400-800 (1979)"),
        .init(file: "PxPlus_IBM_BIOS.ttf", display: "IBM PC (1981)"),
        .init(file: "C64_Pro_Mono-STYLE.ttf", display: "Commodore 64 (1982)"),
        .init(file: "PxPlus_IBM_VGA8.ttf", display: "IBM DOS (1985)"),
        .init(file: "Hermit-medium.otf", display: "Hermit (Modern)"),
        .init(file: "Inconsolata.otf", display: "Inconsolata (Modern)"),
        // 中文点阵字体 —— G3(任意字体×中文×全特效)的门面,内置后换机器也不缺字。
        // ⚠️ 许可留档:v1.2~v1.4 内置的是 Zpix「最像素」的 Mono 转换版,开源前
        //   复核发现 Zpix 是**商业授权字体**(个人免费,但明确禁止修改/转换/传播),
        //   而我们那份正是转换产物 —— 无法随开源仓库分发,已换成本条。
        //   Ark Pixel(方舟像素,TakWolf 作)是 OFL-1.1,可自由随包分发。
        //   用户若自行安装了 Zpix,字体库照样会列出(系统字体扫描不受影响)。
        .init(file: "ArkPixel12pxMono-zh_cn.ttf", display: "方舟像素 (中文)"),
        // 【i18n】display 存中文源文,**别在这里包 L()** —— retroFonts/
        //   retroFamilies 都是只算一次的静态量,包在这里会把译文冻在
        //   注册那一刻的语言上。翻译放到设置页真正显示的地方(FontRow)。
    ]

    /// 注册后的复古字体族名(顺序同 retroFonts;注册失败的条目剔除)
    private(set) static var retroFamilies: [(family: String, display: String)] = []

    private static var registered = false

    /// 进程级注册内置字体(幂等;GUI/探针入口都调)
    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        for font in retroFonts {
            guard let url = Bundle.module.url(forResource: (font.file as NSString).deletingPathExtension,
                                              withExtension: (font.file as NSString).pathExtension,
                                              subdirectory: "Fonts") else {
                FileHandle.standardError.write(Data("字体资源缺失: \(font.file)\n".utf8))
                continue
            }
            var error: Unmanaged<CFError>?
            // 已注册(重复启动/同族系统字体)时返回 false,不视为致命
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let d = descs.first,
               let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                retroFamilies.append((family, font.display))
            }
        }
    }

    // ---- 探测结果进程级缓存(2026-07-28 用户实测"字体多时字体页卡"勘差)----
    // 等宽/图标探测要遍历全部字体各实例化一次(几百字体 = 首访百 ms 级);
    // 此前缓存在页面 @State,切页即丢、每次进字体页都重探 —— 挪到进程级只探一次。
    // 字体集运行时装新字体的场景重启可见,自用终端可接受
    private static var _allFamilies: [String]?
    private static var _monoFamilies: Set<String>?
    private static var _iconFamilies: Set<String>?

    static var cachedAllFamilies: [String] {
        if let c = _allFamilies { return c }
        let v = allFamilies()
        _allFamilies = v
        return v
    }

    static var cachedMonoFamilies: Set<String> {
        if let c = _monoFamilies { return c }
        let v = monospacedFamilies()
        _monoFamilies = v
        return v
    }

    static var cachedIconFamilies: Set<String> {
        if let c = _iconFamilies { return c }
        let v = iconFamilies(from: cachedAllFamilies)
        _iconFamilies = v
        return v
    }

    /// 系统全部字体族(含刚注册的复古字体),字母序
    static func allFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// 等宽字体族集合(用于列表标记,不做过滤)
    static func monospacedFamilies() -> Set<String> {
        let mgr = NSFontManager.shared
        var result: Set<String> = []
        for family in mgr.availableFontFamilies {
            if let f = mgr.font(withFamily: family, traits: [], weight: 5, size: 12), f.isFixedPitch {
                result.insert(family)
            }
        }
        return result
    }

    /// 「图标字体」集合:探测字体是否真的覆盖 Powerline/Nerd Font 私用区字形。
    /// 双判据 = U+E0B0(powerline 实心三角)**且** U+F121(Nerd 补丁的 FontAwesome
    /// code 图标)—— 单探 E0B0 会误收恰好占用该码位的字体(实测:兰亭黑 TC/
    /// 翩翩体/手札体/STIX Math 四款误报),两个码位都占的只有真图标补丁字体。
    /// 不按名字猜("Nerd Font"/"NF"):名字是约定不是保证,字形探测装什么都能归对。
    /// 【学】CTFontGetGlyphsForCharacters:问字体"这些字符你有没有字形",
    ///      返回 glyph id(0 = 没有)—— CoreText 的"能力探测"惯用法;
    ///      找不到字体名时 CTFontCreateWithName 会给替身字体,替身两处皆无 → false。
    static func iconFamilies(from families: [String]) -> Set<String> {
        var out: Set<String> = []
        for family in families {
            let font = CTFontCreateWithName(family as CFString, 12, nil)
            var chars: [UniChar] = [0xE0B0, 0xF121]
            var glyphs: [CGGlyph] = [0, 0]
            CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 2)
            if glyphs[0] != 0 && glyphs[1] != 0 {
                out.insert(family)
            }
        }
        return out
    }

    /// 模糊匹配:query 的字符按序全部出现即命中(大小写/空格不敏感)
    static func fuzzyMatch(_ query: String, _ candidate: String) -> Bool {
        let q = query.lowercased().filter { !$0.isWhitespace }
        if q.isEmpty { return true }
        let c = candidate.lowercased()
        var qi = q.startIndex
        for ch in c {
            if ch == q[qi] {
                qi = q.index(after: qi)
                if qi == q.endIndex { return true }
            }
        }
        return false
    }
}
