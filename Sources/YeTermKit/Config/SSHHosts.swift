// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 远程 SSH 主机库(v1.3 #SSH)
//
// 这个文件:用户在设置里维护的远程服务器清单(名字/主机/端口/用户名/备注)
//   + 每台的密码。两套存储分工:
//   ① 主机信息 → ~/Library/Application Support/YeTerm/ssh-hosts.json
//     (和 config.json 同目录,纯 JSON,类比一张配置表);
//   ② 密码 → macOS 系统钥匙串(Keychain)——绝不进 JSON 明文。
//     类比 Java:数据库表存业务字段,密码进专门的加密凭据库(Vault)。
//
// 语法看点:
//   Security 框架的 SecItemAdd/CopyMatching/Delete —— C 风格 API,参数是
//     [CFString: Any] 字典(kSecClass 等键),返回 OSStatus 错误码;
//     Swift 里桥接调用要 `as CFDictionary`、结果经 CFTypeRef 再转型。
//     类比 JDBC 那种"万物皆参数 Map"的老派接口,包一层就好用了。
//   `struct + Codable` —— 字段即 JSON,一行 JSONEncoder 编解码(等价 Jackson)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import Security

/// 一台远程主机(密码不在这里 —— 见 SSHHostStore.password(for:))
struct SSHHost: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""          // 显示名(菜单/选单/标签标题用)
    var host = ""          // IP 或域名
    var port = 22
    var user = ""          // ssh 必需(产品沟通时补上的字段)
    var note = ""          // 备注
    /// 兼容旧设备(2026-07-30 用户实测:越狱 iPhone 5 只提供 ssh-rsa/ssh-dss,
    /// 而 OpenSSH 9.x 默认停用这些 SHA-1 算法 → "no matching host key type found")
    var legacyAlgorithms = false
    /// 额外 ssh 参数(原样拼进命令行;给上面开关覆盖不到的特殊情况留口子)
    var extraOptions = ""

    /// 组装 ssh 命令行(端口 22 不带 -p,和手敲习惯一致)
    var sshCommand: String { sshCommand(extraFlags: "") }

    /// 带追加参数的组装(降级重试用:把从报错里推出来的兼容参数补在选项区)。
    /// ssh 的语法要求选项都在目标地址**之前**,所以统一在这里拼
    func sshCommand(extraFlags: String) -> String {
        var parts = ["ssh"]
        if port != 22 { parts += ["-p", String(port)] }
        if legacyAlgorithms {
            // 两条都要:前者过"主机密钥算法"协商,后者让 RSA 公钥登录仍可用
            parts += ["-o", "HostKeyAlgorithms=+ssh-rsa",
                      "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa"]
        }
        let extra = extraOptions.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { parts.append(extra) }
        let more = extraFlags.trimmingCharacters(in: .whitespaces)
        if !more.isEmpty { parts.append(more) }
        parts.append("\(user)@\(host)")
        return parts.joined(separator: " ")
    }

    // 【学】手写 init(from:) 而不是让编译器自动生成:自动生成的解码器遇到
    //      JSON 里**缺少**新字段会直接报错 —— 老的 ssh-hosts.json 没有
    //      legacyAlgorithms/extraOptions,用 decodeIfPresent 给默认值,老档照读。
    //      (类比 Jackson 的 @JsonInclude/默认值处理)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        legacyAlgorithms = try c.decodeIfPresent(Bool.self, forKey: .legacyAlgorithms) ?? false
        extraOptions = try c.decodeIfPresent(String.self, forKey: .extraOptions) ?? ""
    }

    init(id: UUID = UUID(), name: String = "", host: String = "", port: Int = 22,
         user: String = "", note: String = "", legacyAlgorithms: Bool = false,
         extraOptions: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.note = note
        self.legacyAlgorithms = legacyAlgorithms
        self.extraOptions = extraOptions
    }

    /// 选单/菜单里的地址短写
    var address: String {
        port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
    }
}

/// 主机清单存取:JSON 数组整读整写(台数是个位数量级,不做增量)。
/// 密码走钥匙串,以主机的 UUID 作账号名 —— 改名/改地址都不影响取密。
final class SSHHostStore {
    static let shared = SSHHostStore()

    private(set) var hosts: [SSHHost] = []
    /// 清单变化广播(菜单重建/设置页刷新监听;类比 Spring 的事件总线)
    static let didChange = Notification.Name("SSHHostStoreDidChange")

    private var path: String {
        NSHomeDirectory() + "/Library/Application Support/YeTerm/ssh-hosts.json"
    }
    /// 测试重定向(探针/auto-drive 不碰真实清单;nil = 正常路径)
    var pathOverride: String?

    private init() { load() }

    func load() {
        let p = pathOverride ?? path
        guard let data = FileManager.default.contents(atPath: p),
              let list = try? JSONDecoder().decode([SSHHost].self, from: data) else {
            hosts = []
            return
        }
        hosts = list
    }

    private func save() {
        let p = pathOverride ?? path
        try? FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(hosts) {
            try? data.write(to: URL(fileURLWithPath: p), options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func upsert(_ host: SSHHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        deletePassword(id: id)
        save()
    }

    // MARK: - 密码(钥匙串)

    private let service = "YeTerm SSH"

    /// 存/更新密码;传空串 = 删除已存密码
    func setPassword(_ password: String, id: UUID) {
        deletePassword(id: id)
        guard !password.isEmpty else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecValueData: Data(password.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func password(id: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword(id: UUID) -> Bool { password(id: id) != nil }

    private func deletePassword(id: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
