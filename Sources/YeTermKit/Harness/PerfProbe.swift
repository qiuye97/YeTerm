// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 分层性能探针(定位「慢在哪一层」)
//
// 背景:2026-07-30 横向跑分(scripts/bench.sh)测出 YeTerm 一处异常 ——
//   处理 ASCII 是全场最快的(每字符 11.8ns,比 Ghostty 的 13.4ns 还快),
//   但处理中文要 219ns/字符,劣化 18.6 倍;而 Ghostty/Terminal.app/
//   cool-retro-term 的劣化都只有 2~4 倍。这 84% 地贡献了与 Ghostty 的总差距。
//
// 但跑分器测的是**端到端**(PTY→解析→渲染),说不出是哪一层慢。
//   这个探针就是来拆层的:同样的字节量,分别单独测
//     ① terminal.feed()  —— 纯 VT 解析(SwiftTerm 内核,不碰渲染)
//     ② buildRow 全网格  —— 纯实例构建(我们自己的渲染前半段,不碰 GPU)
//   两边各跑 ASCII 与 CJK,看**劣化倍数**落在哪一层,就知道该修谁。
//
// 类比:接口慢了,先分清是 SQL 慢还是序列化慢,别一上来就瞎优化。
//
// 语法看点:
//   `ContinuousClock` / `.measure {}` —— Swift 现代计时 API,比 Date() 精确,
//     返回 Duration;`.components.attoseconds` 取到 10^-18 秒的分量。
//   `@inline(never)` —— 禁止编译器内联,免得优化器把空循环整个消掉
//     (测性能时的常见陷阱:被测代码没有副作用就会被优化掉)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import SwiftTerm

/// 分层性能探针(--perf-probe):把「解析」与「实例构建」分开计时,
/// 各跑 ASCII / CJK 两种负载,输出每字符纳秒数与劣化倍数。
public enum PerfProbe {

    /// 探针专用 delegate:不接 PTY,终端的回写(问询应答等)丢弃
    private final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// 生成与 scripts/bench.sh 同构的负载(同样的行宽/字符集),
    /// 保证探针结论能和横向跑分的数字对得上
    private static func payloads(targetBytes: Int) -> (ascii: [UInt8], cjk: [UInt8],
                                                       asciiChars: Int, cjkChars: Int) {
        // ASCII:79 可见字符 + 换行(与 bench 的 gen_scroll_plain 一致)
        var asciiLine = [UInt8]()
        for i in 0..<79 { asciiLine.append(UInt8(33 + (i % 94))) }
        asciiLine.append(0x0a)
        let asciiReps = targetBytes / asciiLine.count
        var ascii = [UInt8](); ascii.reserveCapacity(asciiReps * asciiLine.count)
        for _ in 0..<asciiReps { ascii += asciiLine }

        // CJK:39 个汉字 + 换行(与 bench 的 gen_scroll_cjk 一致)
        let zh = Array("复古终端渲染管线字形图集扫描线余辉磷光荧光屏幕弧度噪点色差机壳反射")
        var cjkStr = ""
        for i in 0..<39 { cjkStr.append(zh[i % zh.count]) }
        cjkStr.append("\n")
        let cjkLine = Array(cjkStr.utf8)
        let cjkReps = targetBytes / cjkLine.count
        var cjk = [UInt8](); cjk.reserveCapacity(cjkReps * cjkLine.count)
        for _ in 0..<cjkReps { cjk += cjkLine }

        return (ascii, cjk, asciiReps * 79, cjkReps * 39)
    }

    @inline(never)
    private static func feed(_ terminal: Terminal, _ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes)
    }

    /// 计时:返回秒
    private static func time(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let d = clock.measure(body)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    public static func run(mb: Double = 6.0) -> Int32 {
        let target = Int(mb * 1024 * 1024)
        let p = payloads(targetBytes: target)

        print("== 分层性能探针 ==")
        print("负载:各 \(String(format: "%.1f", Double(p.ascii.count) / 1024 / 1024)) MB")
        print("  ASCII \(p.asciiChars) 字符 / CJK \(p.cjkChars) 字符"
              + "(同字节量下 CJK 字符数只有 1/3 —— UTF-8 一个汉字 3 字节)")
        print("")

        // ── ① 纯 VT 解析(SwiftTerm 内核)────────────────────────────────
        // 每次用全新 Terminal,免得上一轮的滚动缓冲影响下一轮
        func parseOnly(_ bytes: [UInt8]) -> Double {
            let t = Terminal(delegate: Silent(), options: TerminalOptions.default)
            t.resize(cols: 100, rows: 30)
            return time { feed(t, bytes) }
        }
        _ = parseOnly(Array(p.ascii.prefix(1 << 16)))     // 预热(首次有惰性初始化)

        let pa = parseOnly(p.ascii)
        let pc = parseOnly(p.cjk)
        let paNs = pa / Double(p.asciiChars) * 1e9
        let pcNs = pc / Double(p.cjkChars) * 1e9

        print("① 纯 VT 解析(terminal.feed,不碰渲染)")
        print(String(format: "   ASCII  %7.3fs  →  %7.1f ns/字符", pa, paNs))
        print(String(format: "   CJK    %7.3fs  →  %7.1f ns/字符", pc, pcNs))
        print(String(format: "   劣化倍数:%.1fx", pcNs / paNs))
        print("")

        // ── ② 纯实例构建(我们的渲染前半段,不碰 GPU)────────────────────
        // 把网格填满后反复重建全部行的顶点实例 —— 这是 ContentRenderer
        // 每帧要干的 CPU 活。用 buildRowProbe 走与真实渲染同一段代码。
        func buildOnly(_ bytes: [UInt8], rounds: Int) -> Double {
            let t = Terminal(delegate: Silent(), options: TerminalOptions.default)
            t.resize(cols: 100, rows: 30)
            feed(t, Array(bytes.prefix(1 << 18)))    // 把 30 行网格填满
            guard let probe = ContentRenderer.makeRowProbe(cols: 100) else { return -1 }
            return time {
                for _ in 0..<rounds {
                    for row in 0..<30 { _ = probe(row, t) }
                }
            }
        }
        let rounds = 200
        let ba = buildOnly(p.ascii, rounds: rounds)
        let bc = buildOnly(p.cjk, rounds: rounds)

        print("② 纯实例构建(buildRow 全网格 ×\(rounds) 轮,不碰 GPU)")
        if ba < 0 || bc < 0 {
            print("   ✗ 无法创建探针(Metal 设备不可用?)")
        } else {
            // 每轮 30 行 × 100 列 = 3000 格
            let cells = Double(rounds * 30 * 100)
            print(String(format: "   ASCII  %7.3fs  →  %7.1f ns/格", ba, ba / cells * 1e9))
            print(String(format: "   CJK    %7.3fs  →  %7.1f ns/格", bc, bc / cells * 1e9))
            print(String(format: "   劣化倍数:%.1fx", bc / ba))
        }
        print("")

        // ── 结论指引 ────────────────────────────────────────────────────
        let parseRatio = pcNs / paNs
        let buildRatio = (ba > 0 && bc > 0) ? bc / ba : 1
        print("== 定位 ==")
        print(String(format: "   解析层劣化 %.1fx,构建层劣化 %.1fx", parseRatio, buildRatio))
        if parseRatio > 6 {
            print("   → 瓶颈在 **SwiftTerm 的 VT 解析**(不是我们的渲染层)")
        } else if buildRatio > 6 {
            print("   → 瓶颈在 **我们的实例构建**(ContentRenderer/GlyphAtlas)")
        } else {
            print("   → 两层都不异常;端到端的劣化另有来源(PTY 读取批量/事件回调频次)")
        }
        print("PERF-PROBE-DONE")
        return 0
    }
}
