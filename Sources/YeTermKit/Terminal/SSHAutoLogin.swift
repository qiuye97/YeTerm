// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— SSH 自动登录哨兵(v1.3 SSH)
//
// 这个文件:替用户敲完 ssh 命令后,盯着终端屏幕把"人工问答"自动接掉:
//   ① 首连陌生主机的指纹确认「(yes/no)」→ 自动答 yes(用户拍板:自用图省事);
//   ② 「password:」提示 → 自动输入钥匙串里存的密码(只填一次,填错留人工,
//      防止连环试错触发服务器锁号);
//   ③ **算法协商失败自动降级重连**(v1.3 用户追加,2026-07-30):老设备只支持
//      SHA-1 时代算法时新版 ssh 直接拒谈 —— 从报错里抓对方 offer 的算法列表,
//      补进 -o 参数原地重连(最多两轮),不写 ~/.ssh/config、任何老设备通用。
// 原理:我们就是终端 —— 起一个 0.25s 的轮询定时器扫屏幕最后一行文字,
//   匹配提示样式就往 PTY 注入按键(和提示符热切/粘贴同一注入权),25 秒
//   窗口期过后自动收工。类比:Selenium 盯页面等元素出现再打字。
//
// 语法看点:`static var active: [SSHAutoLogin]` —— 哨兵没人引用会被 ARC
//   立刻回收(Java 有 GC root,Swift 引用计数归零即死),挂在静态数组里
//   自持有,收工时自摘。weak var tv 则相反:不能拽住终端视图不放,
//   pane 关了哨兵要跟着失效。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit

/// 一次连接一个哨兵:arm 后自走自灭
final class SSHAutoLogin {
    private static var active: [SSHAutoLogin] = []

    private weak var tv: EventTerminalView?
    private let password: String?
    /// 目标主机(降级重连要用它重组命令;手敲 ssh 的场景为 nil,不做降级)
    private let host: SSHHost?
    private var yesSent = false
    private var pwSent = false
    private var timer: Timer?
    private var deadline: CFTimeInterval
    /// 已降级重连的轮次(上限 2:一轮补主机密钥算法,再一轮补 kex/cipher/mac)
    private var downgrades = 0
    private var appliedFlags = ""

    /// 测试观察口(auto-drive 断言自动填/自动降级确实发生)
    private(set) static var lastAction = ""

    /// 测试观察口:最近一次**注入 PTY 的重连命令原文**。
    ///
    /// 为什么要单独记这个,而不是让测试去扫屏幕:降级场景里伪造的报错是直接
    /// `feed()` 进终端模拟器的(绕过 PTY),shell 并不知道屏幕上多了几行 ——
    /// 它的光标模型还停在提示符后面。等 zle 收到 Ctrl-U + 命令要重画输入行时,
    /// 它按自己以为的位置重画,和注入的文字互相覆盖,**回显落在哪一格是不确定的**。
    /// 而屏幕回显本来就是 shell 的行为,不是 YeTerm 的契约 —— 我们的契约是
    /// 「把带正确兼容参数的命令发出去」,所以断言就该盯这个。
    private(set) static var lastSentCommand = ""

    static func arm(on tv: EventTerminalView, host: SSHHost? = nil, password: String?) {
        active.append(SSHAutoLogin(tv: tv, host: host, password: password))
    }

    private init(tv: EventTerminalView, host: SSHHost?, password: String?) {
        self.tv = tv
        self.host = host
        self.password = password
        deadline = CACurrentMediaTime() + 25
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let tv, CACurrentMediaTime() < deadline, !pwSent else {
            disarm()
            return
        }
        // 算法协商失败(no matching host key type / key exchange / cipher / MAC):
        // 从报错里抓对方 offer 的算法补参数,原地重连。放在最前面判:这类失败
        // 会直接回到提示符,后面的问答分支都等不到
        if let h = host, downgrades < 2 {
            let recent = Self.recentScreenText(tv, lines: 12)
            if recent.lowercased().contains("no matching") {
                let opts = SSHConnectivity.legacyOptions(fromError: recent)
                if !opts.isEmpty, !appliedFlags.contains(opts) {
                    appliedFlags = appliedFlags.isEmpty ? opts : appliedFlags + " " + opts
                    downgrades += 1
                    yesSent = false
                    pwSent = false
                    deadline = CACurrentMediaTime() + 25   // 重连给足新的窗口期
                    Self.lastAction = "downgrade:\(opts)"
                    ShellIntegration.debugLog("SSH 算法降级重连(第 \(downgrades) 轮):\(opts)")
                    // 记住这台机器的兼容参数,下次直接带上(只加参数,不动其它字段)
                    var remembered = h
                    remembered.extraOptions = remembered.extraOptions.isEmpty
                        ? appliedFlags
                        : remembered.extraOptions + " " + opts
                    if SSHHostStore.shared.hosts.contains(where: { $0.id == h.id }) {
                        SSHHostStore.shared.upsert(remembered)
                    }
                    // \u{15} = Ctrl-U(先清掉行编辑器里可能残留的半截输入)
                    let cmd = h.sshCommand(extraFlags: appliedFlags)
                    Self.lastSentCommand = cmd
                    tv.send(txt: "\u{15}" + cmd + "\r")
                    return
                }
            }
        }

        let line = Self.lastScreenLine(tv)
        // 指纹确认:「Are you sure ... (yes/no/[fingerprint])?」
        if !yesSent, line.contains("yes/no") {
            tv.send(txt: "yes\r")
            yesSent = true
            Self.lastAction = "yes"
            return
        }
        // 密码提示:「user@host's password:」/「Password:」—— 行尾冒号才算,
        // 避免误伤输出里恰好带 password 字样的普通文本
        if let pw = password, !pwSent {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().contains("password"), t.hasSuffix(":") {
                tv.send(txt: pw + "\r")
                pwSent = true
                Self.lastAction = "password"
                disarm()
            }
        }
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
        Self.active.removeAll { $0 === self }
    }

    /// 屏幕末尾若干**非空**行,拼成"去折行"的一整串(用于匹配报错原文)。
    /// 两条都是实测踩出来的(2026-07-30 自测):
    ///   ① 必须跳过空行 —— 刚 clear 过时内容都在屏幕上半部,死取"末 N 行"全是空白;
    ///   ② 必须去掉行边界 —— 终端窄时报错会被折断成
    ///      "…no ma" / "tching host key type…",按行匹配永远对不上
    ///      (窗口窄/主机名长的真实场景同样中招,不是只有测试环境)。
    private static func recentScreenText(_ tv: EventTerminalView, lines: Int) -> String {
        let t = tv.getTerminal()
        var out: [String] = []
        for row in stride(from: t.rows - 1, through: 0, by: -1) {
            guard out.count < lines, let line = t.getLine(row: row) else { continue }
            var s = ""
            for col in 0..<t.cols {
                let ch = t.getCharacter(for: line[col])
                if ch != "\u{0}" { s.append(ch) }
            }
            // 去掉行尾填充空格:折行的下一行才能无缝接上
            while s.hasSuffix(" ") { s.removeLast() }
            if !s.isEmpty { out.append(s) }
        }
        return out.reversed().joined()
    }

    /// 屏幕最后一行非空文字(滤零宽 filler;同 auto-drive 的 screenLine 手法)
    private static func lastScreenLine(_ tv: EventTerminalView) -> String {
        let t = tv.getTerminal()
        for row in stride(from: t.rows - 1, through: 0, by: -1) {
            guard let line = t.getLine(row: row) else { continue }
            var s = ""
            for col in 0..<t.cols {
                let ch = t.getCharacter(for: line[col])
                if ch != "\u{0}" { s.append(ch) }
            }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
