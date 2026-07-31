// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 波特率限速器:让字符像老设备那样一个个吐出来
//
// 这个文件干嘛的:1980 年代你敲一条命令,字符不是"啪"一下整屏出现,而是顺着
//   串口/调制解调器一个一个爬出来 —— 300 bps 时每秒才 37 个字符,你能看着
//   它一行行长出来。这个类就是把 PTY 送来的字节先攒住,再按设定的比特率
//   慢慢放给终端内核,还原那种节奏。
//
// 核心算法只有三行(小学数学):
//   每帧配额 = 比特率 ÷ 8 × 这帧过了多少秒 + 上帧剩下的零头
//   本帧放出 = 配额的整数部分
//   零头     = 配额的小数部分,留到下帧继续攒
//   ——「零头」是关键:110 bps 时每帧配额才 0.23 字节,不攒就永远放不出一个字。
//
// 类比 Java/Web:就是个令牌桶(token bucket)限流器,只不过令牌 = 字节,
//   补充速率 = 比特率÷8。Guava 的 RateLimiter、Nginx 的 limit_req 同一个套路。
//
// 语法看点:
//   `[UInt8]` + `head` 下标游标 —— 不用 removeFirst(那是 O(n) 整体搬移,
//     大积压下会被反复搬),而是只挪游标,等消费过半再一次性压缩。
//     类比 Java 的 ByteBuffer position/compact。
//   `weak self` —— 定时器闭包里必须弱引用,否则视图关不掉(循环引用);
//     类比 Java 里回调持有 Activity 导致内存泄漏。
//   `CACurrentMediaTime()` —— 单调递增的系统时钟(秒),不受用户改系统时间影响。
// ─────────────────────────────────────────────────────────────────────────────
import QuartzCore

/// 字节吞吐限速器(v1.4):按选定波特率把 PTY 输出**慢慢吐**给终端内核,
/// 复现调制解调器年代「文字一个一个蹦出来」的节奏。
///
/// **语义**:每帧配额 = `bitRate × Δt ÷ 8 + 上帧零头`,即**每字节按 8 位算**
/// (纯数据位,不含起止位),取整数部分吐出、小数存回下一帧累加。
///
/// **线程约定**:全主线程(与项目其余部分一致 —— SwiftTerm 类型非 Sendable)。
/// `enqueue` 由 `dataReceived` 在主队列调用,定时器也在主 RunLoop。
///
/// **为什么可以安全地把字节流切碎**:SwiftTerm 的 `Terminal.handlePrint` 有
/// `readingBuffer.putbackBuffer` 机制 —— 多字节 UTF-8 序列若尾字节还没到,
/// 首字节会暂存到下一次 feed(我们 fork 的 CJK 快路径也显式检查
/// `putbackBuffer.isEmpty` 才走 ASCII 捷径)。所以逐字节喂中文不会乱码。
final class ByteRateLimiter {
    /// 每字节的位数。取 8 = 纯数据位(真串口含起止位应是 10),
    /// 这样档位标称值与常见复古终端软件的口径一致。
    static let bitsPerByte = 8.0

    /// 档位表(bps)。0 = 不限速,放在最前面当缺省。
    /// 前 12 档是真实的串口/调制解调器速率史;后 3 档是链路速率
    /// (224 kbps ≈ 早期宽带、1.5 Mbps = T1、10 Mbps = 10BASE-T 以太网)。
    static let presetRates: [Int] = [
        0, 110, 300, 1200, 2400, 4800, 9600, 14400, 19200,
        28800, 33600, 38400, 56000, 224000, 1_500_000, 10_000_000,
    ]

    /// 档位显示名。分界写法:≤9600 写 bps、
    /// 14400~224000 写 kbps 保一位小数、≥1.5M 写 Mbps —— 逐档核对过
    /// (14.4 / 19.2 / 28.8 / 33.6 / 38.4 / 56.0 / 224.0 kbps、1.5 / 10.0 Mbps)
    static func rateLabel(_ bps: Int) -> String {
        switch bps {
        case ..<1: return L("不限速")
        case ..<10_000: return "\(bps) bps"
        case ..<1_000_000: return String(format: "%.1f kbps", Double(bps) / 1000.0)
        default: return String(format: "%.1f Mbps", Double(bps) / 1_000_000.0)
        }
    }

    /// 积压上限。限速是**观感特效,不是流控** —— 有人 `cat` 一个大文件时继续
    /// 排队只会让终端看起来卡死十几分钟,那不是复古是故障。超过上限就整批吐完
    /// (后续输入照旧限速)。设置页对这条行为有说明。
    static let maxBacklog = 1 << 20   // 1 MiB

    /// 比特率(bps);0 或负数 = 不限速(直通)
    var bitsPerSecond: Int = 0 {
        didSet {
            guard bitsPerSecond != oldValue else { return }
            if bitsPerSecond <= 0 { flush() }
        }
    }

    var isLimiting: Bool { bitsPerSecond > 0 }

    /// 放行回调:把字节交给终端内核(= `super.dataReceived(slice:)`)
    private let release: (ArraySlice<UInt8>) -> Void

    private var pending: [UInt8] = []
    private var head = 0                  // pending 中已放行到的位置
    private var leftover = 0.0             // 不足一字节的配额零头
    private var lastTick: CFTimeInterval = 0
    private var timer: Timer?

    init(release: @escaping (ArraySlice<UInt8>) -> Void) {
        self.release = release
    }

    deinit { timer?.invalidate() }

    var backlogCount: Int { pending.count - head }

    /// PTY 来的一批字节。不限速时原样直通(零开销、逐字节与限速前完全一致)。
    func enqueue(_ slice: ArraySlice<UInt8>) {
        guard isLimiting else {
            release(slice)
            return
        }
        pending.append(contentsOf: slice)
        if backlogCount > Self.maxBacklog {
            flush()
            return
        }
        startTimerIfNeeded()
    }

    /// 立刻吐完积压(用户按 ⌃C、切到不限速、或积压超上限时)
    func flush() {
        stopTimer()
        leftover = 0
        guard head < pending.count else {
            pending.removeAll(keepingCapacity: true)
            head = 0
            return
        }
        let rest = pending[head...]
        pending = []
        head = 0
        release(rest)
    }

    // MARK: - 计时

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        // 60Hz 步进:即使在 110 bps(每 72ms 才一个字符)也只是大多数帧配额不足
        // 一字节、由 leftover 攒着 —— 每次 tick 的成本就是几次浮点运算。
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 1.0 / 120.0
        // .common 模式:菜单/拖窗口等模态 runloop 期间也继续吐字(否则拉着滚动条
        // 输出就冻住,一看就假)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0, now - lastTick)
        lastTick = now

        guard isLimiting else {
            flush()
            return
        }

        // 每帧配额 = 比特率 ÷ 8 × Δt + 上帧零头
        let budget = Double(bitsPerSecond) / Self.bitsPerByte * dt + leftover
        let whole = budget.rounded(.down)
        leftover = budget - whole

        let available = backlogCount
        guard available > 0 else {
            stopTimer()
            leftover = 0
            return
        }
        let n = min(Int(whole), available)
        guard n > 0 else { return }

        let chunk = pending[head..<(head + n)]
        head += n
        // 消费过半就压缩,避免 pending 无限增长(游标法的常规配套)
        if head > 4096 && head * 2 >= pending.count {
            pending.removeFirst(head)
            head = 0
        }
        release(chunk)

        if backlogCount == 0 {
            stopTimer()
            leftover = 0
        }
    }
}
