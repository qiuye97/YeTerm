// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 系统通知中心的"小喇叭"(v1.2 #5,纯本机)
//
// 这个文件:把"长命令跑完了/后台响铃了"送进 macOS 通知中心。
//   类比 Web 的 Notification API:先请求授权,再投递标题+正文。
//   工程要点:UserNotifications 框架**必须跑在正经 .app 包里**
//   (swift run 直跑的裸二进制没有 bundle 身份,调它会崩)——
//   所以先探测 bundleIdentifier,裸跑环境整体降级为"什么都不做",
//   探针/开发环境天然安全。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import UserNotifications

/// 通知中心封装:授权惰性请求 + 无 bundle 环境静默降级。
/// ⚠️ 纪律(用户裁决):本功能**纯本机**,永远不做任何远程/手机推送。
enum Notifier {
    /// swift run 裸二进制无 bundle 身份 → UserNotifications 不可用
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private static var authRequested = false

    /// 投递一条本机通知(标题+正文)。首次调用顺手请求授权;
    /// 用户在系统设置里拒绝过则系统自行丢弃,这里不感知不打扰。
    static func post(title: String, body: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        if !authRequested {
            authRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        center.add(req)
    }
}
