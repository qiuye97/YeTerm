// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 本地网络权限触发器(v1.3,2026-07-30 事故根修)
//
// 背景:macOS 15 起"访问局域网"是一项隐私权限。用户实测在 YeTerm 里
//   `ssh 内网IP` 报 "No route to host"(ARP 都不通),而公网正常、别的终端正常。
// 第一版修法只在打包 Info.plist 里补了声明键 —— 不够:**系统只登记
//   「app 自己的进程」发出的申请**。我们的局域网流量全是 ssh/curl 这些
//   子进程发的,系统压根没把 YeTerm 记成申请者,于是既不弹窗、也不出现在
//   系统设置的「本地网络」列表里,只能一直静默拒绝。
// 所以这里让 app 主进程亲自做两件事:
//   ① Bonjour 浏览(NWBrowser)—— macOS 认定的标准触发点,弹的就是
//      "YeTerm 想查找并连接你本地网络上的设备";
//   ② 直连预检(NWConnection)—— 顺带判断"是不是真被拒了",能给用户
//      明确提示而不是让他对着 No route to host 猜。
// 授权一次之后,app 名下的所有子进程(ssh/ping/curl)跟着获权。
//
// 语法看点:
//   `Network` 框架的 NWBrowser/NWConnection —— Apple 的现代网络 API,
//     状态用回调推送(stateUpdateHandler),类比 Java 的 NIO + 监听器。
//   `@MainActor` / DispatchQueue.main.asyncAfter —— 延时回主线程做收尾,
//     类比 Java 的 ScheduledExecutor + Swing invokeLater。
//   `static var shared` 单例这里用 enum 静态成员(不可实例化的命名空间)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Network

enum LocalNetworkPermission {
    /// 浏览器要拿住(NWBrowser 被回收就等于取消,授权弹窗也就不出来了)
    private static var browser: NWBrowser?
    private static var probeConn: NWConnection?
    private static var alertShown = false

    /// 是否是内网/链路本地地址(只有连这类地址才需要本地网络权限)
    static func isLocalAddress(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            // 非 IPv4 字面量:主机名走 DNS,是否内网不好判 —— 交给系统,不主动触发
            return false
        }
        switch (parts[0], parts[1]) {
        case (10, _): return true                                   // 10.0.0.0/8
        case (192, 168): return true                                // 192.168.0.0/16
        case (172, 16...31): return true                            // 172.16.0.0/12
        case (169, 254): return true                                // 链路本地
        case (127, _): return false                                 // 本机回环不受限
        default: return false
        }
    }

    /// 触发系统授权登记(Bonjour 浏览 3 秒即收工;只为让系统认得这个申请者)
    static func trigger() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: nil), using: params)
        b.stateUpdateHandler = { state in
            ShellIntegration.debugLog("本地网络 Bonjour 浏览状态: \(state)")
        }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            browser?.cancel()
            browser = nil
        }
    }

    /// 直连预检:可达 → true。用于连接前判断"权限是不是被拦了"。
    /// 【学】NWConnection 是异步的:结果经 completion 回调送出(类比回调式 HTTP 客户端)
    static func probe(host: String, port: Int, timeout: TimeInterval = 3,
                      completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            completion(false)
            return
        }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        probeConn = conn
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            probeConn = nil
            completion(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed(let err):
                ShellIntegration.debugLog("本地网络预检失败 \(host):\(port) → \(err)")
                finish(false)
            case .waiting(let err):
                // EHOSTUNREACH 会走 waiting(系统在重试)—— 权限被拦时就卡这里
                ShellIntegration.debugLog("本地网络预检 waiting \(host):\(port) → \(err)")
            default:
                break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    /// 连接内网主机前的把关:触发授权登记 + 预检不通就给一次明确提示
    /// (提示只弹一次,别烦人;用户点"打开设置"直达隐私面板)
    static func ensureBeforeConnect(host: String, port: Int) {
        guard isLocalAddress(host) else { return }
        trigger()
        probe(host: host, port: port) { ok in
            guard !ok, !alertShown else { return }
            alertShown = true
            let alert = NSAlert()
            alert.messageText = Lf("连不上内网主机 %@", host)
            alert.informativeText = """
            macOS 的「本地网络」权限没有授予 YeTerm,局域网流量会被系统直接拦掉\
            (表现为 ssh 报 No route to host)。

            请在 系统设置 → 隐私与安全性 → 本地网络 里打开 YeTerm 的开关,\
            然后重新连接。
            """
            alert.addButton(withTitle: L("打开设置"))
            alert.addButton(withTitle: L("稍后"))
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 菜单「检查本地网络权限…」:主动触发一次授权登记并回报结果
    static func runDiagnostic(probeHost: String?, completion: @escaping (String) -> Void) {
        trigger()
        // 允许 host:port 写法(自检时拿公网 22 端口做对照,排除"整体没网")
        var probePort = 22
        var probeHost = probeHost
        if let raw = probeHost, let colon = raw.lastIndex(of: ":"),
           let p = Int(raw[raw.index(after: colon)...]) {
            probePort = p
            probeHost = String(raw[..<colon])
        }
        guard let h = probeHost else {
            completion(L("已向系统申请本地网络权限。若弹出授权请点「允许」;")
                       + L("没弹窗就去 系统设置 → 隐私与安全性 → 本地网络 手动打开 YeTerm。"))
            return
        }
        probe(host: h, port: probePort) { ok in
            completion(ok ? Lf("可达:%1$@:%2$d 连通。", h, probePort)
                          : Lf("连不上 %1$@:%2$d —— 若是内网地址,请在 系统设置 → 隐私与安全性 → 本地网络 ", h, probePort)
                            + L("里确认 YeTerm 的开关已打开(若列表里没有,先点一次「打开设置」")
                            + L("再回来重试一次连接)。"))
        }
    }
}
