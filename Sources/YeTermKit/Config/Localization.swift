// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 多语言(i18n):同一个界面怎么说两种话
//
// 这个文件:整个 app 的翻译层。用法极简 —— 界面上凡是给人看的中文,外面套一层
//   `L(...)`:
//       Text("亮度")        →  Text(L("亮度"))
//   中文界面时 `L` 原样返回;英文界面时去查表返回 "Brightness"。
//
// 三个设计选择,都是有意为之:
//
//   ① **键就是中文原文**,不是 "settings.brightness" 这种符号键。
//      好处:改动量最小(只加一层括号)、代码读起来还是中文、**查不到翻译时
//      自动回落中文**而不是显示一个丑陋的键名。作者是中文母语者,中文永远是
//      最完整的那一份 —— 让它当"源语言"最省事。
//      代价:同一个中文词在不同语境下如果英文不同(比如"确定"),会撞车;
//      真遇到了就在中文里加个限定词区分(见下面的 `L(_:context:)`)。
//
//   ② **译文放独立的 .strings 文件**(Resources/L10n/en.strings),不硬编码在
//      Swift 里。好处:想加一门语言 = 丢一个新文件进去,翻译的人完全不用碰
//      Swift 代码;.strings 也是苹果生态的标准格式,翻译工具都认。
//
//   ③ **不用系统的 NSLocalizedString**。系统那套在 app 启动时就把语言定死了,
//      切语言必须重启。我们自己管,才能做到设置页里一点就**立刻**全部变过来
//      (和主题热切换一样的体验)。
//
// 【学】`ObservableObject` + `@Published`:SwiftUI 的响应式基础。
//   `language` 一变就自动广播,凡是 `@ObservedObject var l10n = L10n.shared`
//   的视图,body 会重算一遍 —— 整个设置页的文字就这么"自己"变了。
//   类比前端:一个全局 store,组件订阅它,store 一变组件重渲染。
// 【学】AppKit 那半边(菜单栏、OSD)不是响应式的,得手动重建,所以额外发一条
//   `Notification`。类比:前端框架管不到的那部分 DOM,得自己发事件去刷新。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

/// 界面语言。存 UserDefaults(**不是**主题 JSON)——
/// 语言是使用者的个人偏好,不该跟着主题走:换个配色不该把界面变成英文。
public enum AppLanguage: String, CaseIterable, Sendable {
    case system     // 跟随系统
    case zhHans     // 简体中文
    case english    // English

    /// 设置页选单上显示的名字。**故意各写各的母语**(而不是跟着当前界面语言翻),
    /// 这样界面误切成看不懂的语言时,还能照着母语名找回来 —— 常见做法。
    public var nativeName: String {
        switch self {
        case .system:  return "跟随系统 / System"
        case .zhHans:  return "简体中文"
        case .english: return "English"
        }
    }
}

/// 实际生效的语言(把 `.system` 解析掉之后只剩这两种)
public enum ResolvedLanguage: String, Sendable {
    case zhHans
    case english
}

/// 翻译层单例。
///
/// **线程约定**:全主线程(与项目其余部分一致)。
public final class L10n: ObservableObject {
    public static let shared = L10n()

    /// AppKit 那半边(菜单栏/OSD)靠这条通知重建
    public static let didChangeNotification = Notification.Name("YeTermLanguageDidChange")

    private static let defaultsKey = "YeTermUILanguage"

    /// 使用者选的语言。改它会:①刷新所有 SwiftUI 界面;②发通知让 AppKit 重建;③写盘。
    @Published public var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            // 先同步 AppleLanguages 再 resolve:.system 模式要先撤掉覆盖项,
            // Locale.preferredLanguages 才有机会读到真正的系统语言
            Self.syncAppleLanguagesOverride(for: language)
            resolved = Self.resolve(language)
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    // MARK: - AppKit 自带界面的语言跟随(2026-08-06 用户需求)

    /// 把「界面语言」设置同步为进程的 `AppleLanguages` 偏好覆盖项。
    ///
    /// 背景:`L()` 只管 **YeTerm 自己写的**文案;文件选择器(NSOpenPanel)、标准
    /// 按钮、标签页右键菜单这些 **AppKit 自带**的界面,语言由进程启动时的
    /// AppleLanguages 偏好 × app 声明的语言列表决定,`L()` 够不着。用户实测:
    /// 中文界面下打开背景图片选择器却是英文的。
    /// 写 app 域的 AppleLanguages 覆盖项(faked "系统语言",只影响本 app)即可让
    /// 这半边也跟随设置;`.system` = 删掉覆盖项回落真系统语言。
    /// 三种组合已逐一实测(裸二进制/带声明 .app × 有无覆盖项,2026-08-06)。
    ///
    /// ⚠️ 两个已知边界:
    /// ① AppKit 在进程启动时就把语言定死了 —— 启动最早处(main.swift)有一次
    ///    bootstrap 同步,所以**每次启动都正确**;运行中途切换语言,系统对话框
    ///    要下次启动才跟上(自家文案照旧热切换)。
    /// ② `swift run` 的裸二进制必须有语言声明这套机制才生效 —— 已用链接器把
    ///    最小 Info.plist 内嵌进可执行(见 Package.swift 的 linkerSettings 注释)。
    private static func syncAppleLanguagesOverride(for lang: AppLanguage) {
        switch lang {
        case .zhHans:  UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .system:  UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// 进程启动最早处调用(main.swift,在任何 AppKit/本地化被触碰之前):
    /// 按上次保存的「界面语言」写好 AppleLanguages,让**本次启动**的系统对话框
    /// 就说对的语言。不走 `shared`(避免过早初始化单例的副作用顺序问题)。
    public static func bootstrapProcessLanguage() {
        let saved = UserDefaults.standard.string(forKey: defaultsKey)
        syncAppleLanguagesOverride(for: saved.flatMap(AppLanguage.init(rawValue:)) ?? .zhHans)
    }

    /// 当前实际生效的语言
    public private(set) var resolved: ResolvedLanguage

    /// 译文表:中文原文 → 目标语言。中文界面时用不到(直接返回原文)。
    private var table: [String: String] = [:]
    private var loadedFor: ResolvedLanguage?

    private init() {
        // 缺省 = 简体中文。**注意不是 .system** —— 这是一个中文优先的项目,
        // 作者与主要使用者都是中文用户;英文用户到设置里点一下即可。
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let lang = saved.flatMap(AppLanguage.init(rawValue:)) ?? .zhHans
        self.language = lang
        self.resolved = Self.resolve(lang)
    }

    private static func resolve(_ lang: AppLanguage) -> ResolvedLanguage {
        switch lang {
        case .zhHans:  return .zhHans
        case .english: return .english
        case .system:
            // 【学】`Locale.preferredLanguages` 是系统「语言与地区」里的排序列表,
            //   形如 ["zh-Hans-CN", "en-US"]。只认第一项的语言代码就够了。
            let code = Locale.preferredLanguages.first ?? "en"
            return code.hasPrefix("zh") ? .zhHans : .english
        }
    }

    /// 取译文。查不到 → 原样返回中文(**这是特性**:新加的界面文案哪怕忘了翻译,
    /// 英文界面上也只是这一句是中文,不会变成空白或键名)。
    public func t(_ zh: String) -> String {
        guard resolved != .zhHans else { return zh }
        loadIfNeeded()
        return table[zh] ?? zh
    }

    /// 带语境的取译文:中文相同、英文不同时用。
    /// 表里的键写成 `中文\u{1}语境`,由 `.strings` 文件里的 `"中文|语境"` 转换而来。
    public func t(_ zh: String, context: String) -> String {
        guard resolved != .zhHans else { return zh }
        loadIfNeeded()
        return table["\(zh)\u{1}\(context)"] ?? table[zh] ?? zh
    }

    /// 探针专用:拿到当前已载入的英文表(用于覆盖率与占位符断言)
    public static func enTableForTesting() -> [String: String] {
        loadTable(for: .english)
    }

    private func loadIfNeeded() {
        guard loadedFor != resolved else { return }
        loadedFor = resolved
        table = Self.loadTable(for: resolved)
    }

    private static func loadTable(for lang: ResolvedLanguage) -> [String: String] {
        guard lang != .zhHans else { return [:] }
        let name: String
        switch lang {
        case .english: name = "en"
        case .zhHans:  return [:]
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "strings",
                                          subdirectory: "L10n"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        return parse(text)
    }

    /// 极简 .strings 解析器。只认这一种行:
    ///     "中文" = "English";
    /// 另支持 `//` 行注释与空行。带语境的键写成 `"中文|语境"`。
    ///
    /// 【学】为什么自己写而不用 `NSDictionary(contentsOf:)`:那个 API 走的是
    ///   系统的 plist/strings 解析,遇到一处语法错会**整份返回 nil** ——
    ///   翻译文件里一个漏掉的分号就让整个英文界面回落中文,还不告诉你哪错了。
    ///   自己解析可以逐行跳过坏行,坏一行只丢一句。
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            guard let (key, value) = parseLine(line) else { continue }
            out[key.replacingOccurrences(of: "|", with: "\u{1}")] = value
        }
        return out
    }

    /// 拆一行 `"a" = "b";`。手写扫描而不是正则 —— 要正确处理值里的转义引号。
    private static func parseLine(_ line: String) -> (String, String)? {
        var chars = Array(line)
        func scanQuoted(from i: inout Int) -> String? {
            while i < chars.count, chars[i] != "\"" { i += 1 }
            guard i < chars.count else { return nil }
            i += 1                                   // 跳过开引号
            var buf = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    let n = chars[i + 1]
                    buf.append(n == "n" ? "\n" : (n == "t" ? "\t" : n))
                    i += 2
                    continue
                }
                if c == "\"" { i += 1; return buf }
                buf.append(c)
                i += 1
            }
            return nil                               // 引号没闭合 → 坏行
        }
        var i = 0
        guard let key = scanQuoted(from: &i), !key.isEmpty else { return nil }
        // 键与值之间必须有个 '='
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == "=" else { return nil }
        i += 1
        guard let value = scanQuoted(from: &i) else { return nil }
        return (key, value)
    }
}

/// 翻译速记。全项目界面文案都套这一层。
///
/// 【学】Swift 允许定义**全局函数**(不必挂在某个类下),这种到处都要用的
///   小工具正适合。名字只有一个字母是刻意的:它会出现几百次,长了看着累。
public func L(_ zh: String) -> String { L10n.shared.t(zh) }

/// 带语境版本:同一句中文在不同地方英文不一样时用,例如
/// `L("确定", context: "对话框按钮")`。
public func L(_ zh: String, context: String) -> String {
    L10n.shared.t(zh, context: context)
}

/// 带占位符的翻译。**句子里要塞变量时必须用这个,不能用 `L("...\(变量)...")`**。
///
/// 为什么:Swift 的字符串插值是在**运行时先拼好**再传进来的 ——
///     L("连不上 \(host)")     // 传进来的已经是 "连不上 192.168.1.5"
/// 查表时拿这个拼好的整句去找,表里永远没有,于是永远回落中文。
/// 正确写法是把变量留成占位符,查完表再填:
///     Lf("连不上 %@", host)   // 查 "连不上 %@" → "Can't reach %@" → 填 host
///
/// 【学】`CVarArg...` 是 Swift 的**可变参数**(类比 Java 的 `Object... args`),
///   `String(format:)` 与 C 的 printf 同源:`%@` 收字符串、`%d` 收整数。
///   多个参数时建议写成 `%1$@`、`%2$@` 这种**带序号**的形式 ——
///   不同语言的语序不一样,带序号译者才能自由调换先后。
public func Lf(_ zh: String, _ args: CVarArg...) -> String {
    String(format: L10n.shared.t(zh), arguments: args)
}
