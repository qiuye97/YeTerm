// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— SSH 连通测试 + 算法自动降级(v1.3,2026-07-30 用户追加)
//
// 两件事共用一套逻辑:
//   ① 设置页「测试连通」按钮:真跑一次 ssh 握手(BatchMode 不问密码),
//      把结果翻译成人话(通了 / 要兼容参数 / 端口没开 / 网络不通)。
//   ② 连接时自动降级重试:老设备(越狱 iPhone、旧 NAS/路由器/交换机)
//      只支持 SHA-1 时代的算法,新版 OpenSSH 默认停用 → 报
//      "no matching host key type found. Their offer: ssh-rsa,ssh-dss"。
//      我们**从报错里把对方 offer 的算法列表抓出来**,原样补进 -o 参数重连 ——
//      不写 ~/.ssh/config、不依赖任何本地配置,换任何一台老设备都通用。
//
// 安全阀:抓出来的算法可能是本机 ssh 已彻底移除的(实测 ssh-dss 就是,
//   硬塞进去 ssh 会直接报 Bad key types),所以组装完先用 `ssh -G` 验一遍,
//   不合法就退回一套人工挑好的保守清单。
//
// 语法看点:
//   `Process` —— 起子进程跑命令行工具(类比 Java 的 ProcessBuilder);
//     stdout/stderr 用 Pipe 收,readDataToEndOfFile 同步读到底。
//   `DispatchQueue.global().async { ... }` + 回主线程 —— 网络等待不能卡界面,
//     后台跑完再回主线程更新 UI(类比 Android 的 AsyncTask / JS 的 await + setState)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

enum SSHConnectivity {
    /// 测试结论(summary 直接给用户看)
    struct Result {
        var ok: Bool                 // 握手是否走通(能到认证阶段就算通)
        var summary: String
        var legacyOptions: String    // 非空 = 需要这些兼容参数才通(已自动带上)
    }

    // MARK: - 从报错里推兼容参数

    /// 报错文本 → 需要补的 `-o` 参数串(空串 = 这不是算法协商问题)。
    /// 优先用对方 offer 的算法列表(通用,不猜设备型号);抓不到就用保守清单。
    static func legacyOptions(fromError text: String) -> String {
        let low = text.lowercased()
        // "Their offer: ssh-rsa,ssh-dss" → ["ssh-rsa"](dss 本机已移除,带上会报错)
        func offered() -> [String] {
            guard let r = text.range(of: "Their offer:") else { return [] }
            // 只吃算法名允许的字符(字母数字 - _ @ . ,),遇到空格/其它字符即停 ——
            // 报错在终端里可能已被折行拼成一整串,不能靠换行断句(实测教训)
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_@.,")
            var list = ""
            for ch in text[r.upperBound...] {
                if ch == " " && list.isEmpty { continue }     // 跳过 "offer:" 后的空格
                if allowed.contains(ch) { list.append(ch) } else { break }
            }
            return list.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("dss") }
        }
        var opts: [String] = []
        if low.contains("no matching host key type") {
            let algs = offered().isEmpty ? ["ssh-rsa"] : offered()
            opts.append("-o HostKeyAlgorithms=+\(algs.joined(separator: ","))")
            // 同时放宽公钥算法:否则带 RSA 私钥登录的老机器认证阶段又会卡住
            opts.append("-o PubkeyAcceptedAlgorithms=+ssh-rsa")
        }
        if low.contains("no matching key exchange method") {
            let algs = offered().isEmpty
                ? ["diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1",
                   "diffie-hellman-group-exchange-sha1"]
                : offered()
            opts.append("-o KexAlgorithms=+\(algs.joined(separator: ","))")
        }
        if low.contains("no matching cipher") {
            let algs = offered().isEmpty ? ["aes128-cbc", "3des-cbc"] : offered()
            opts.append("-o Ciphers=+\(algs.joined(separator: ","))")
        }
        if low.contains("no matching mac") {
            let algs = offered().isEmpty ? ["hmac-sha1", "hmac-sha1-96", "hmac-md5"] : offered()
            opts.append("-o MACs=+\(algs.joined(separator: ","))")
        }
        let joined = opts.joined(separator: " ")
        // 安全阀:本机 ssh 不认的算法要挡掉,否则重连会以另一个错失败
        return joined.isEmpty || validate(options: joined) ? joined : fallbackOptions(low)
    }

    /// 保守清单(对方 offer 抓不到或含本机不识别的算法时用)
    private static func fallbackOptions(_ lowercasedError: String) -> String {
        var opts = ["-o HostKeyAlgorithms=+ssh-rsa", "-o PubkeyAcceptedAlgorithms=+ssh-rsa"]
        if lowercasedError.contains("key exchange") {
            opts.append("-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1")
        }
        if lowercasedError.contains("cipher") {
            opts.append("-o Ciphers=+aes128-cbc,3des-cbc")
        }
        if lowercasedError.contains("mac") {
            opts.append("-o MACs=+hmac-sha1")
        }
        let joined = opts.joined(separator: " ")
        return validate(options: joined) ? joined : "-o HostKeyAlgorithms=+ssh-rsa"
    }

    /// 用 `ssh -G`(只解析配置不联网)验参数是否被本机 ssh 接受
    static func validate(options: String) -> Bool {
        let args = tokenize(options) + ["-G", "localhost"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 把 "-o A=b -o C=d" 拆成参数数组(Process 要数组,不能整串塞)
    static func tokenize(_ s: String) -> [String] {
        s.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - 连通测试(设置页按钮)

    /// 真跑一次 ssh 握手(不问密码、6 秒超时);需要兼容参数时自动重试一次并如实报告
    static func test(host: SSHHost, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var extra = host.extraOptions
            var (status, err) = runSSH(host: host, extraFlags: extra)
            var used = ""
            // 算法协商失败 → 抓对方 offer 补参数重试一次
            if status != 0, !legacyOptions(fromError: err).isEmpty, !handshakeReached(err) {
                let opts = legacyOptions(fromError: err)
                used = opts
                extra = extra.isEmpty ? opts : extra + " " + opts
                (status, err) = runSSH(host: host, extraFlags: extra)
            }
            let result = classify(status: status, err: err, legacyUsed: used)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// stderr 里出现认证相关字样 = 握手已经走通(只是没给密码)
    private static func handshakeReached(_ err: String) -> Bool {
        let low = err.lowercased()
        return low.contains("permission denied") || low.contains("publickey")
            || low.contains("password") || low.contains("authentication")
    }

    private static func classify(status: Int32, err: String, legacyUsed: String) -> Result {
        let low = err.lowercased()
        let tag = legacyUsed.isEmpty ? "" : L("(已自动补兼容参数)")
        if status == 0 {
            return Result(ok: true, summary: Lf("连通,且免密登录成功%@", tag), legacyOptions: legacyUsed)
        }
        if handshakeReached(err) {
            return Result(ok: true, summary: Lf("连通,握手成功,等待密码/密钥认证%@", tag),
                          legacyOptions: legacyUsed)
        }
        if low.contains("no matching") {
            return Result(ok: false, summary: L("算法协商失败,且本机 ssh 已不支持对方提供的算法:")
                          + firstLine(err), legacyOptions: legacyUsed)
        }
        if low.contains("connection refused") {
            return Result(ok: false, summary: L("网络可达,但端口没开(对方 sshd 没跑?)"),
                          legacyOptions: legacyUsed)
        }
        if low.contains("no route to host") || low.contains("network is unreachable")
            || low.contains("network is down") {
            return Result(ok: false, summary: L("网络不通 —— 内网地址请检查「本地网络」权限")
                          + L("(菜单 服务器 → 检查本地网络权限…)"), legacyOptions: legacyUsed)
        }
        if low.contains("timed out") || low.contains("timeout") {
            return Result(ok: false, summary: L("连接超时(地址/端口写错,或对方不在线)"),
                          legacyOptions: legacyUsed)
        }
        if low.contains("could not resolve") || low.contains("name or service not known") {
            return Result(ok: false, summary: L("主机名解析失败"), legacyOptions: legacyUsed)
        }
        return Result(ok: false, summary: firstLine(err).isEmpty ? Lf("连接失败(exit %d)", status)
                                                                : firstLine(err),
                      legacyOptions: legacyUsed)
    }

    private static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
    }

    /// 起一次 ssh:BatchMode 不问密码、accept-new 自动收指纹、6 秒超时,只跑 `true`
    private static func runSSH(host: SSHHost, extraFlags: String) -> (Int32, String) {
        var args = tokenize(extraFlags)
        if host.legacyAlgorithms {
            args += ["-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa"]
        }
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                 "-o", "StrictHostKeyChecking=accept-new"]
        if host.port != 22 { args += ["-p", String(host.port)] }
        args += ["\(host.user)@\(host.host)", "true"]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return (-1, Lf("无法启动 ssh:%@", String(describing: error)))
        }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
