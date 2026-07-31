// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— imgcat 多段传输协议的补课(v1.2 #4 实测修复)
//
// 用户实测:装了官方 imgcat 脚本却不出图。挖脚本源码发现——新版 imgcat
//   **默认不再用一条巨型序列**(那是 --legacy 模式),而是拆成三种小序列:
//     MultipartFile=参数   (开始,带尺寸等参数)
//     FilePart=一段base64  (正文,每段 200 字节,发很多条)
//     FileEnd              (结束)
//   SwiftTerm 只认老式单条 File=,多段的静默丢弃 → 无图。
//
// 修法:SwiftTerm 的 OSC 分发是"用户注册的处理器优先"(上游注释明说
//   allows override)—— 我们注册 1337 接管:老式 File 照旧支持(逻辑对齐
//   上游),多段三兄弟补上,拼完整后走同一条 public createImage 入口。
//
// 语法看点:`Data(base64Encoded:options:.ignoreUnknownCharacters)` ——
//   宽容解码(跳过换行等杂质);多段拼接用字符串数组 + joined,避免
//   反复大字符串拼接的 O(n²)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import SwiftTerm

extension EventTerminalView {
    /// 多段传输的进行时状态(每视图一份,关联对象挂载)
    private final class MultipartImageState {
        var params: [String: String] = [:]
        var chunks: [String] = []
        var active = false
        func reset() {
            params = [:]
            chunks = []
            active = false
        }
    }

    private static var multipartKey: UInt8 = 0

    private var multipartState: MultipartImageState {
        if let s = objc_getAssociatedObject(self, &Self.multipartKey) as? MultipartImageState {
            return s
        }
        let s = MultipartImageState()
        objc_setAssociatedObject(self, &Self.multipartKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    /// 接管 OSC 1337(TermHost 装配时调用)。上游分发规则:注册的处理器优先。
    func installITerm2ImageHandler() {
        getTerminal().registerOscHandler(code: 1337) { [weak self] data in
            self?.handleOSC1337(data)
        }
    }

    private func handleOSC1337(_ data: ArraySlice<UInt8>) {
        // key = 到第一个 "=" 为止;注意 FileEnd **没有等号**(整段就是 key,
        // 首版在这栽过:guard 有 = 直接把 FileEnd 拦死,多段永远收不了尾)
        let eq = data.firstIndex(of: UInt8(ascii: "=")) ?? data.endIndex
        let key = String(bytes: data[data.startIndex..<eq], encoding: .utf8) ?? ""
        guard eq < data.endIndex || key == "FileEnd" else { return }
        let state = multipartState
        switch key {
        case "File":
            // 老式单条:File=k=v;k=v:BASE64(与上游 osciTerm2 行为对齐)
            guard let colon = data[eq...].firstIndex(of: UInt8(ascii: ":")) else { return }
            let kv = Self.parseKeyValues(data[(eq + 1)..<colon])
            guard kv["inline"] == "1" else { return }
            guard let img = Data(base64Encoded: Data(data[(colon + 1)...]),
                                 options: .ignoreUnknownCharacters) else { return }
            deliverImage(img, kv)
        case "MultipartFile":
            // 开始:参数段无 base64(imgcat 新版默认路径)
            state.reset()
            state.params = Self.parseKeyValues(data[(eq + 1)...])
            state.active = true
        case "FilePart":
            guard state.active else { return }
            if let part = String(bytes: data[(eq + 1)...], encoding: .utf8) {
                state.chunks.append(part)
            }
        case "FileEnd":
            defer { state.reset() }
            guard state.active, state.params["inline"] == "1",
                  let img = Data(base64Encoded: state.chunks.joined(),
                                 options: .ignoreUnknownCharacters) else { return }
            deliverImage(img, state.params)
        default:
            break   // SetUserVar 等其它 key:本 app 无消费,静默忽略
        }
    }

    private func deliverImage(_ imgData: Data, _ kv: [String: String]) {
        // createImage 是 TerminalView 的 public delegate 实现:解码/切条/attach 全托上游
        createImage(source: getTerminal(), data: imgData,
                    width: Self.parseDimension(kv["width"]),
                    height: Self.parseDimension(kv["height"]),
                    preserveAspectRatio: (kv["preserveAspectRatio"] ?? "1") == "1")
    }

    /// `k=v;k=v` 参数段解析(照抄上游语义)
    private static func parseKeyValues(_ data: ArraySlice<UInt8>) -> [String: String] {
        var kv: [String: String] = [:]
        guard let text = String(bytes: data, encoding: .utf8) else { return kv }
        for pair in text.split(separator: ";") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            kv[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return kv
    }

    /// 尺寸参数解析:auto / N% / Npx / N(cells);上限对齐上游防膨胀
    private static func parseDimension(_ v: String?) -> ImageSizeRequest {
        guard let v, v != "auto" else { return .auto }
        if v.hasSuffix("%"), let n = Int(v.dropLast()), n > 0, n <= 100 { return .percent(n) }
        if v.hasSuffix("px"), let n = Int(v.dropLast(2)), n > 0, n < 4096 { return .pixels(n) }
        if let n = Int(v), n > 0, n < 200 { return .cells(n) }
        return .auto
    }
}
