// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 渲染总指挥:CRT 特效层(全项目最核心的文件,阅读顺序第 7 站)
//
// 这个文件:盖在窗口最上层的一块 Metal 画布(MTKView),整个 CRT 画面从这出。
// 先建立宏观图景 —— 每一帧画面的流水线:
//   ① 各 pane 的 ContentRenderer 把"字符网格"画成文字纹理(GPU 上的位图);
//   ② 合成:把各 pane 纹理按位置拼进一张全窗大图 + 画荧光分割线;
//   ③ 派生:对大图算辉光模糊(bloom)、余辉累积(burn-in);
//   ④ CRT 主着色器:扫描线/弧度/噪点/机壳…一次性上屏(见 Shaders/CRT.metal)。
// 类比 Web:①② ≈ 服务端渲染出 DOM,④ ≈ 全屏 CSS filter/WebGL 后处理。
//
// 两个重要的性能思想(面试级知识点😄):
//   ▸ 事件驱动:平时一帧都不重画;shell 输出/按键才"置脏"(contentDirty),
//     下一帧才真正干活 —— 类比前端的"按需重渲染"而非每帧 setState。
//   ▸ 丢旧保新:GPU 排队超过 2 帧就跳过本帧(inFlight 信号量),
//     保证画的永远是最新状态,这是"按住方向键出现残影"事故的根修。
//
// 语法看点:
//   `DispatchSemaphore` —— GCD 信号量,类比 Java 的 Semaphore。
//   `private final class Source` —— 嵌套类当"每 pane 的记账本"。
//   `weak var view:` —— 弱引用防泄漏:pane 关掉后这里自动变 nil。
//   `guard ... else { return }` —— "不满足条件就提前退出",Swift 最常用的
//     防御式写法,把主逻辑保持在最外层缩进(类比 Java 的 early return)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import MetalKit
import SwiftTerm

/// 实时 CRT overlay:盖在**整个窗口**上方的 MTKView —— 一个窗口 = 一台"显示器"。
///
/// **多 pane 合成(M2 重构,用户裁决:分屏不该像多台显示器)**:
/// 每个分屏 pane 自带 ContentRenderer(字形图集直渲、行级脏缓存),各自的内容纹理
/// 按 pane 视口位摆进一张窗口级合成画面,pane 之间画**荧光分割线**(内容空间纯白,
/// 经 CRT 染色成荧光色、吃辉光),然后整张画面走一遍 CRT 链 —— 机壳/弧度/扫描线
/// 永远只有一套。
///
/// **驱动模型(M1a-1,事件驱动,与 cool-retro-term 同构)**:
/// - CPU 捕获(大头)只由事件触发:SwiftTerm 的 `rangeChanged`(内容/光标变更,
///   其内部已 ~60fps 节流合并)→ 置脏;另有 500ms 兜底。
/// - GPU 全屏 pass(便宜)每帧照跑:time 动画 + 光标(uniform,不进捕获)。
/// - 输入完全透明:hitTest → nil、不接受 firstResponder。
/// - app 失活 → 全停摆(后台零负载);回前台恢复。
final class MetalOverlayView: MTKView {
    private let mtl: MetalContext
    private let renderer: OffscreenRenderer
    private let effects: EffectChain?         // M1b: 辉光模糊 + 余辉乒乓
    private var bloomTexture: MTLTexture?     // 内容更新时重算
    private let noiseTexture: MTLTexture?

    /// pane 内容源(附着/剥离由窗口控制器管理)
    private final class Source {
        weak var view: EventTerminalView?
        let content: ContentRenderer
        var dirtyRows = IndexSet()
        var allDirty = true
        init(view: EventTerminalView, content: ContentRenderer) {
            self.view = view
            self.content = content
        }
    }
    private var sources: [Source] = []

    /// 窗口控制器注入:焦点 pane(光标/IME 归属)
    var focusedViewProvider: (() -> EventTerminalView?)?
    /// 窗口控制器注入:pane 几何 + 分割线(overlay 视图坐标,AppKit y-up)
    var layoutProvider: (() -> (panes: [(view: EventTerminalView, rect: CGRect)], dividers: [CGRect]))?

    private var keyMonitor: Any?
    private var activeObservers: [NSObjectProtocol] = []
    private var recoveryObservers: [NSObjectProtocol] = []   // 唤醒/解锁/换屏(v1.4 事故修复)
    private var watchdog: Timer?                             // 渲染循环看门狗
    private let t0 = CACurrentMediaTime()
    private var sourceTexture: MTLTexture?      // 合成画面(按尺寸复用)
    private var focusedCellPx: (w: Int, h: Int) = (0, 0)
    private var focusedRectPx = CGRect.zero     // 焦点 pane 在合成画面中的位置(物理 px,原点左上)

    // 光标平滑滑移:离散跳格 → 连续移动(视觉暂留导致的"多个光标"感知级修复)
    private var smoothCursorUV: SIMD2<Float>?

    private var lastInputTime: CFTimeInterval = 0   // 闪烁相位基准:打字常亮,空闲闪烁
    private var lastCaptureTime: CFTimeInterval = 0
    // 真实活动时刻(按键/内容事件)。闪烁判定曾错用 lastCaptureTime:
    // 500ms 兜底重绘不停刷新它 → 「活动后 1s 常亮」永远成立 → 光标永不闪
    private var lastActivityTime: CFTimeInterval = 0
    private var contentDirty = true
    private weak var caretMirror: NSView?           // SwiftTerm 的 caretView(镜像其显隐)

    // 静态跳帧:无动画特效且内容/光标未变时不取 drawable(省 GPU/功耗)
    private var lastPresentedCursor: SIMD4<Float> = .init(repeating: -1)
    private var lastPresentedCursorOn: Float = -1

    // YETERM_PERF=1:内容构建耗时 EMA 埋点 + CRT 全屏 pass 的 GPU 真实耗时 EMA
    private let perfEnabled = ProcessInfo.processInfo.environment["YETERM_PERF"] != nil
    private var perfEMA: Double = 0
    private var perfCount = 0
    private var gpuEMA: Double = 0
    private var gpuCount = 0

    /// GPU 帧耗时记账(completed handler 来自后台线程,已收口到主线程再调这里)
    private func recordGPUTime(_ ms: Double) {
        gpuEMA = gpuEMA == 0 ? ms : gpuEMA * 0.95 + ms * 0.05
        gpuCount += 1
        if gpuCount % 120 == 0 {
            FileHandle.standardError.write(Data(String(format: "[perf] CRT pass GPU EMA %.3f ms @%dfps挡\n",
                                                       gpuEMA, preferredFramesPerSecond).utf8))
        }
    }

    // 在途帧限流:限 2 帧在途,落后时跳过本帧(丢旧保新)——多光标残影根修
    private let inFlight = DispatchSemaphore(value: 2)

    /// ⌘E 手动开关
    var userHidden = false { didSet { applyVisibility() } }
    private var lastPreedit: String?          // IME 预编辑轮询(焦点 pane)

    /// 光标行为配置(设置页接管)
    var cursorBlinks = true
    var cursorStyle: Float = 0     // 0 块/1 下划线/2 竖线

    /// 分屏荧光线样式(设置页):0 实线 / 1 虚线段 / 2 点线
    var dividerStyle: Int = 0

    // ── 刷新率挡位 + 低电量自动降帧(v1.1 #3)────────────────────────────
    // 【学】`didSet` 是属性观察器:每次赋值后自动执行(类比 Vue 的 watch)。
    //      设置页改挡位 → 这里立刻换 display link 频率,无需手动通知。
    /// 用户选择的刷新率挡(设置页:30/60/120/跟随显示器;低电量模式下自动压到 ≤30)。
    /// `0` = 跟随显示器(取 `NSScreen.maximumFramesPerSecond`)
    var preferredRate: Int = 60 { didSet { updateFrameRate() } }

    /// 当前窗口所在显示器的最高刷新率(设置页显示用;拿不到时按 60 保守估计)。
    /// 【学】`NSScreen.maximumFramesPerSecond` 是 macOS 12+ 的 API,ProMotion 屏返回 120,
    ///      普通屏返回 60 —— 这是"能不能真跑到 120"的唯一权威依据。
    var displayMaxFPS: Int { (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60 }

    /// 帧率换算规则(抽成纯函数便于自测;真机跑到多少受显示器限制,但**规则**可测)。
    /// · `preferred <= 0` = 跟随显示器 → 取显示器上限;
    /// · 否则取挡位与上限的较小者 —— 60Hz 屏上选 120 必须如实降到 60,
    ///   不能让设置页显示 120 而实际只跑 60(那是骗人);
    /// · 低电量模式再压到 ≤30。
    static func resolveFPS(preferred: Int, displayMax: Int, lowPower: Bool) -> Int {
        let cap = max(displayMax, 1)
        let want = preferred <= 0 ? cap : preferred
        return lowPower ? min(want, cap, 30) : min(want, cap)
    }

    /// 实际生效的帧率;设置页据此如实告诉用户"真正跑多少"
    var effectiveFPS: Int {
        Self.resolveFPS(preferred: preferredRate, displayMax: displayMaxFPS,
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// 后台动画(v1.1.2 用户裁决做成开关):开 = app 失活时特效照常播(拟真,
    /// crterm 同款行为;空闲动画实测 ~1.6% GPU,代价很小);关 = 失活即停摆最省电。
    /// 窗口被完全遮挡/最小化时无论开关都停(renderTick 的 occlusion guard)。
    var animateInBackground = true

    private func updateFrameRate() {
        // v1.4:挡位**钳到当前显示器的实际上限**。
        // 以前写死 `preferredFramesPerSecond = preferredRate`,选 120 而屏只有 60 时,
        // MTKView 内部照样会被 display link 钳到 60 —— 结果一样,但设置页会骗人
        // (显示"120 帧"而实际 60)。显式钳一下,`effectiveFPS` 才能如实告诉用户真跑多少。
        // 低电量模式(系统设置里的)→ 无论用户挡位,压到 30fps 省电。
        let fps = effectiveFPS
        preferredFramesPerSecond = fps
        // ⚠️ 光调 display link 不够(v1.4 实测):SwiftTerm 的 `queuePendingDisplay` 原本把
        // 内容变更通知合并在 16.67ms = **60fps 硬顶**,与显示器刷新率无关 —— 高刷屏上
        // 由 PTY 输出驱动的滚动照样只有 60fps,display link 跑再快也只是重复呈现同一帧内容。
        // 我们 fork 里把它做成可设的 `updateCoalescingFPS`(缺省 60 = 上游行为),这里同步。
        for src in sources { src.view?.updateCoalescingFPS = fps }
    }

    // 特效动画节流(crterm effectsFrameSkip=3 同款语义,历史版 fps=24/20):
    // 噪点/闪烁/抖动这类"纯 time 驱动"的动画以 ~20fps 跳变即够复古观感,
    // 60fps 全速跑纯属烧 GPU。内容/光标变化和开关机动画不受此节流(全速)。
    private var lastAnimFrameTime: CFTimeInterval = 0
    private let animFrameInterval: CFTimeInterval = 1.0 / 20.0 - 0.002   // 留 2ms 余量防节拍错过

    // ── 开机/关机动画状态机(v1.1)──────────────────────────────────────
    // 进度不存在 uniforms 里(applySettings 会整体重建 uniforms),而是每帧由
    // 「起播时刻 + 当前时刻」现算 —— 和光标闪烁同一套"时间驱动"思路。
    // 【学】`(() -> Void)?` 是"可选的无参闭包"类型:关机动画放完后要通知
    //      窗口控制器"现在可以真正关窗了",就存一个回调在这里(类比 JS 的
    //      把 callback 存成员变量,动画结束时调用)。
    var powerAnimationEnabled = true            // 设置页开关(CRTConfig.powerOnEffect)
    private var powerAnimStart: CFTimeInterval = -1   // <0 = 无动画进行中
    private var powerAnimReverse = false        // false=开机(0→1) true=关机(1→0)
    private var powerOffCompletion: (() -> Void)?
    /// 开机/关机动画速度系数(v1.2 补丁用户追加,4 档:0.6 慢/1.0 标准/
    /// 1.6 快/2.5 极速;时长 = 基准 ÷ 系数,开关机同一系数保持手感一致)
    var powerSpeedFactor: Double = 1.0
    private var powerOnDuration: CFTimeInterval { 1.3 / max(powerSpeedFactor, 0.1) }
    private var powerOffDuration: CFTimeInterval { 0.45 / max(powerSpeedFactor, 0.1) }

    /// 播放显像管开机动画(窗口创建时由控制器调用;开关关闭则直接稳态)。
    /// 不立即计时:慢机器上首帧要等着色器运行时编译(M1 实测几百 ms),
    /// 从 init 起播会把"亮点"前段整段吃掉 —— 挂起等首帧真正上屏才开表,
    /// 挂起期间输出全黑(= 显像管未通电,与窗口黑底衔接)。
    private var powerOnPending = false

    func playPowerOn() {
        guard powerAnimationEnabled else { return }
        powerOnPending = true
    }

    /// 播放关机动画(画面塌缩成亮线熄灭),放完回调 completion(主线程)。
    /// 返回是否真的会播:开关关闭/特效隐藏/渲染停摆时返回 false 且**不**调 completion
    /// —— 调用方据此走"直接关窗"分支,避免同步回调引发的重入。
    /// 【学】@discardableResult:允许调用方忽略返回值而不产生编译警告。
    @discardableResult
    func playPowerOff(completion: @escaping () -> Void) -> Bool {
        guard powerAnimationEnabled, !userHidden, !isPaused, window != nil,
              !sources.isEmpty else {
            return false
        }
        powerOnPending = false      // 首帧都没出就关窗:直接黑灭,不播塌缩
        powerAnimReverse = true
        powerAnimStart = CACurrentMediaTime()
        powerOffCompletion = completion
        // 兜底定时器:动画中途 overlay 被挂起(app 失活)时 renderTick 不再跑,
        // 回调也必须必达 —— 否则窗口永远关不掉。两条路径都先取走回调再调用,天然幂等。
        DispatchQueue.main.asyncAfter(deadline: .now() + powerOffDuration + 0.25) { [weak self] in
            guard let self, let done = self.powerOffCompletion else { return }
            self.powerAnimStart = -1
            self.powerAnimReverse = false
            self.powerOffCompletion = nil
            done()
        }
        return true
    }

    /// 本帧动画进度(≥1 = 稳态;每帧现算,dumpFrame 侧会强制回稳保证确定性)
    // ---- OSD 调节面板(v1.2 #14):像素风屏上菜单,合成进画面过 CRT 管线 ----
    private(set) var osdController: OSDController?

    func ensureOSD(model: SettingsModel) -> OSDController {
        if let o = osdController { return o }
        let o = OSDController(ctx: mtl, model: model)
        osdController = o
        return o
    }

    // ---- CRT 盒绘标签条(2026-08-06):荧光屏顶部,机壳样式的窗口内标签栏 ----
    // 控制器持有(strong),这里 weak 引用防环;frame 由控制器布局时算好经闭包供给
    weak var tabStrip: TabStripController?
    var tabStripFrameProvider: (() -> CGRect?)?
    // 布局几何签名(重影修复):pane 落点/标签条位置上次捕获时的快照
    private var lastLayoutSignature: [CGRect] = []

    func makeTabStrip() -> TabStripController { TabStripController(ctx: mtl) }

    /// 单视图整幅置脏(标签切换:后台期间的脏行追踪跨越了挂载/尺寸变化,不可信)
    func markAllDirty(view: EventTerminalView) {
        sources.first { $0.view === view }?.allDirty = true
        scheduleCapture()
    }

    /// 清空余辉缓冲(标签切换用:上一"频道"的画面别拖到新频道上当重影)
    func resetBurnIn() {
        effects?.resetBurnIn()
    }

    /// 屏面点(AppKit y-up 视图坐标)→ 内容纹理坐标(2026-08-07 命中修正)。
    /// 屏幕弧度 + 机壳最小带都会把顶部内容"顶"离它在纹理里的位置 —— 标签条
    /// 画在纹理里,点击命中必须先过与 CRT shader **同一套**映射,否则条越矮
    /// 偏得越明显(用户实测:极简块/翻页卡几乎整条错过)。公式逐行对照
    /// crt_fragment:distortCoordinates(含 screenInset padding)→ clamp →
    /// 内缩逆映射;弧度为 0 且机壳关时恒等。
    func contentPoint(fromViewPoint p: CGPoint) -> CGPoint {
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return p }
        let inset = uniforms.screenInset
        let one = SIMD2<Float>(1, 1)
        // AppKit y-up → 纹理 uv(y-down)
        var uv = SIMD2<Float>(Float(p.x / W), Float(1 - p.y / H))
        let padded = uv * (one + inset * 2) - inset
        let cc = padded - SIMD2<Float>(0.5, 0.5)
        let dist = (cc.x * cc.x + cc.y * cc.y) * uniforms.screenCurvature
        var curved = padded + cc * (1 + dist) * dist
        curved = simd_clamp(curved, SIMD2<Float>(), one)
        uv = (curved + inset) / (one + inset * 2)
        return CGPoint(x: CGFloat(uv.x) * W, y: (1 - CGFloat(uv.y)) * H)
    }

    // ---- 粘贴确认面板(v1.2 #6,v1.3 改 OSD 同款画布合成) ----
    private(set) var pasteGuardController: PasteGuardController?

    func ensurePasteGuard() -> PasteGuardController {
        if let p = pasteGuardController { return p }
        let p = PasteGuardController(ctx: mtl)
        pasteGuardController = p
        return p
    }

    /// 自测口(v1.3 锯齿事故哨兵):合成画面与 drawable 是否逐像素 1:1。
    /// 破了就说明 CRT 采样在做非整数重采样 —— 屏幕上表现为部分行发毛
    var pixelMappingExactForTesting: Bool {
        guard let s = sourceTexture, drawableSize.width > 0 else { return false }
        return s.width == Int(drawableSize.width.rounded())
            && s.height == Int(drawableSize.height.rounded())
    }

    /// 1:1 不变量兜底(锯齿事故根修的另一半):窗口刚缩放时会出现
    /// "合成画面还是旧尺寸、drawable 已经是新尺寸" —— 此时 CRT 把旧图
    /// **非整数缩放**贴到新尺寸上(x/y 比例还各不相同),文字被重采样:
    /// 有的行正落像素中心(锐利)、有的行落在两行之间(发毛),就是用户
    /// 截图里"同样两行一清一糊"的成因。尺寸不等就当场重捕获。
    private func ensureCompositeMatchesDrawable() {
        let dw = Int(drawableSize.width.rounded()), dh = Int(drawableSize.height.rounded())
        guard dw > 0, dh > 0 else { return }
        if sourceTexture?.width != dw || sourceTexture?.height != dh {
            performCapture()
        }
    }

    /// 自测口:走一遍上面的兜底(GUI 里由 renderTick 每帧驱动;
    /// 无界面探针窗口收不到 draw 回调,需手动踢一脚)
    func syncCompositeForTesting() { ensureCompositeMatchesDrawable() }

    /// 自测口:合成/drawable 实际尺寸(诊断打印用)
    var mappingSizesForTesting: (comp: (Int, Int), drawable: (Int, Int)) {
        ((sourceTexture?.width ?? -1, sourceTexture?.height ?? -1),
         (Int(drawableSize.width.rounded()), Int(drawableSize.height.rounded())))
    }

    /// 自测口:焦点 pane 在合成画面里的落点(必须落在整数物理像素上)
    var focusedPaneOriginForTesting: CGPoint { focusedRectPx.origin }

    /// 焦点 pane 的字符格尺寸(物理像素)。演示 GIF 按「要多少列多少行」反推窗口
    /// 大小时要用它 —— 字号/字体不同,一格多大只有渲染过一帧才知道
    var focusedCellPxForTesting: (w: Int, h: Int) { focusedCellPx }

    // ---- 服务器选单(v1.3 SSH,⇧⌘O;OSD 同款画布合成) ----
    private(set) var serverPickerController: ServerPickerController?

    func ensureServerPicker() -> ServerPickerController {
        if let p = serverPickerController { return p }
        let p = ServerPickerController(ctx: mtl)
        serverPickerController = p
        return p
    }

    // ---- 消磁彩蛋(v1.2 #13):径向波纹+色差飙大+晃动,0.8s 指数衰减 ----
    private var degaussStart: CFTimeInterval = -1
    private var degaussTimer: Timer?
    private let degaussDuration = 0.8

    var degaussActive: Bool {
        degaussStart > 0 && CACurrentMediaTime() - degaussStart < degaussDuration
    }

    /// 按下消磁钮(菜单/⇧⌘M/点机壳)。重复按=重新起振(真消磁钮也这样)
    func playDegauss() {
        guard !bootScreenActive else { return }
        degaussStart = CACurrentMediaTime()
        degaussTimer?.invalidate()
        degaussTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.degaussActive {
                t.invalidate()
                self.degaussTimer = nil
            }
            self.scheduleRepaint()
        }
    }

    // ---- 换台效果(v1.2 #12):切主题瞬间快速塌缩→展开,复用开机动画管线 ----
    private var channelSwitchStart: CFTimeInterval = -1
    private let channelCollapse = 0.12      // 收缩到横亮线
    private let channelExpand = 0.20        // 展开成新配色
    var channelFXEnabled = true             // 设置接线(缺省开)

    var channelSwitchActive: Bool {
        channelSwitchStart > 0
            && CACurrentMediaTime() - channelSwitchStart < channelCollapse + channelExpand
    }

    /// 播一次换台闪断。只挡关机动画/自检中(真打架的两种);开机 pending 不挡 ——
    /// 探针环境 MTKView draw 循环可能不跑、pending 永远挂着(自检 Timer 解耦同教训),
    /// 且 pending=黑屏时播换台无害。
    /// `force`(v1.2 补丁):⌘E 开 CRT 方向此刻 channelFXEnabled 还是普通模式
    /// 钳制后的 false(设置广播 50ms 防抖未到)—— 调用方已判过用户开关,绕过钳制
    func playChannelSwitch(force: Bool = false) {
        guard force || channelFXEnabled else { return }
        guard !bootScreenActive,
              !(powerAnimReverse && powerAnimStart >= 0) else { return }
        channelSwitchStart = CACurrentMediaTime()
        scheduleRepaint()
        // 短动画不进 animated 模式:错峰 repaint 喂帧(visual bell 同款)
        for delay in stride(from: 0.04, through: 0.36, by: 0.04) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scheduleRepaint()
            }
        }
    }

    private func currentPowerProgress(now: CFTimeInterval) -> Float {
        if powerOnPending { return 0 }      // 等首帧起播:通电前全黑
        // 换台:1 → 0.25(横线态,不全灭)→ 1;结束自动清
        if channelSwitchStart > 0 {
            let t = now - channelSwitchStart
            if t < channelCollapse {
                return Float(1 - 0.75 * (t / channelCollapse))
            } else if t < channelCollapse + channelExpand {
                return Float(0.25 + 0.75 * ((t - channelCollapse) / channelExpand))
            }
            channelSwitchStart = -1
        }
        guard powerAnimStart >= 0 else { return 1 }
        let dur = powerAnimReverse ? powerOffDuration : powerOnDuration
        let t = (now - powerAnimStart) / dur
        if powerAnimReverse {
            return Float(max(1 - t, 0))     // 结束判定在 renderTick(要触发回调)
        }
        if t >= 1 {
            powerAnimStart = -1             // 开机放完,自然回稳
            return 1
        }
        return Float(t)
    }

    var uniforms = CRTUniforms()

    /// 工厂:Metal 不可用返回 nil(init() 与 NSView 非 failable 签名冲突,不能直接 override)
    static func make() -> MetalOverlayView? {
        guard let mtl = MetalContext() else { return nil }
        return MetalOverlayView(mtl: mtl)
    }

    private init(mtl: MetalContext) {
        self.mtl = mtl
        self.renderer = OffscreenRenderer(ctx: mtl)
        self.effects = EffectChain(ctx: mtl)
        self.noiseTexture = CRTPass.loadNoiseTexture(device: mtl.device)
        super.init(frame: .zero, device: mtl.device)

        colorPixelFormat = .bgra8Unorm            // sRGB 编码值直算(禁 _srgb)
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = true
        framebufferOnly = true
        isPaused = true                            // start() 时开跑(display link 驱动)
        enableSetNeedsDisplay = false
        delegate = self
        autoresizingMask = [.width, .height]

        uniforms.staticNoise = 0.10
        uniforms.screenCurvature = 0
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("不支持 storyboard") }

    // 输入透明
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    // MARK: - pane 附着

    func attach(_ view: EventTerminalView) {
        sources.append(Source(view: view, content: ContentRenderer(ctx: mtl)))
        view.updateCoalescingFPS = effectiveFPS   // 新 pane 也要吃到当前帧率(v1.4)
        scheduleCapture()
    }

    func detach(_ view: EventTerminalView) {
        sources.removeAll { $0.view === view || $0.view == nil }
        scheduleCapture()
    }

    // MARK: - 生命周期

    func start() {
        stop()
        isPaused = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            self?.lastInputTime = CACurrentMediaTime()
            return ev
        }
        if activeObservers.isEmpty {
            let nc = NotificationCenter.default
            activeObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.animateInBackground else { return }   // 后台动画开 → 不停摆
                self.suspend()
            })
            activeObservers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
                self?.resume()
            })
            // 低电量模式开/关 → 重算帧率挡(通知可能来自后台线程,queue: .main 收口)
            activeObservers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                  object: nil, queue: .main) { [weak self] _ in
                self?.updateFrameRate()
            })
        }
        installRecoveryObservers()
        startWatchdog()
        updateFrameRate()
    }

    func stop() {
        isPaused = true
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    private func suspend() { stop() }

    private func resume() {
        // ⚠️ 这里**不能**再写 `guard isPaused else { return }`(v1.4 事故修复):
        // animateInBackground 缺省为 true ⇒ 失活时根本不调 suspend() ⇒ isPaused 一直是
        // false ⇒ 老写法在 didBecomeActive 时直接早退,连一次强制重捕获都没有。
        // 回前台/解锁本来就是最该做一次全量恢复的时机,无条件做。
        if isPaused { start() }
        forceFullRecovery(reason: "回到前台")
    }

    // MARK: - 唤醒/解锁恢复 + 渲染循环看门狗(v1.4 事故修复)
    //
    // 事故现象(用户 2026-07-31 实测):外接屏全屏 + 锁屏过夜,早上解锁后
    //   「文字全没了、只剩扫描线,最下方还有 2~3 像素行的字符残骸」。
    //
    // 机理(排查结论):本视图 `enableSetNeedsDisplay = false`,**纯 display link 驱动**,
    //   而 display link 绑在**具体某台显示器**上。外接屏睡眠/断开再回来时它可能不重启
    //   ⇒ draw 回调再也不来 ⇒ 画面永久冻在最后一次上屏的那一帧。
    //   而那一帧恰好是在"睡眠期间窗口几何退化"时画的(终端被缩成极小),
    //   于是只剩一条窄带内容;扫描线是着色器按**屏幕坐标**算的,所以照样铺满全屏。
    //   三个现象全部对上,且能解释"看多久都不恢复"。
    //
    // ⚠️ 老实说:这条**没能在本机复现**(auto-drive 场景 27 模拟的尺寸突变会自愈),
    //   是排除法收敛出来的最可能机制 —— 信号量无泄漏、内容纹理每帧全量重画、
    //   500ms 兜底捕获也在。所以修法上不赌单一原因:
    //   ① 精准派:监听唤醒/解锁/屏幕参数变化,当场全量恢复;
    //   ② 兜底派:**看门狗** —— 只要"窗口可见、未暂停"却超过 1.5 秒没有绘制回调,
    //      就判定循环已死并重启。不管根因是什么都能自愈,代价是一个 2 秒的空转定时器。
    private var lastTickTime: CFTimeInterval = 0
    /// 合成画面重建次数(自测口:验证恢复动作真的作废并重建了纹理)
    private(set) var compositeRebuilds = 0

    /// 全量恢复:重启渲染循环 + 作废全部缓存几何/纹理,下一帧从头重建
    private func forceFullRecovery(reason: String) {
        // display link 可能已死:isPaused 翻一下促使 MTKView 重建它
        if !isPaused {
            isPaused = true
            isPaused = false
        }
        sources.forEach { $0.allDirty = true }
        sourceTexture = nil       // 强制按**当前** drawable 尺寸重建合成画面
        bloomTexture = nil
        contentDirty = true
        lastCaptureTime = 0       // 让 500ms 兜底立刻生效
        lastTickTime = CACurrentMediaTime()
        if ProcessInfo.processInfo.environment["YETERM_PERF"] != nil {
            FileHandle.standardError.write(Data("[recover] \(reason)\n".utf8))
        }
    }

    /// 看门狗的判定策略(抽成纯函数便于自测:真实的"display link 死了"在
    /// 活着的循环里没法伪造 —— 一帧就把 lastTickTime 刷新了)。
    /// 语义:窗口可见、非主动暂停、且超过 1.5 秒没有绘制回调 ⇒ 判定循环已死。
    static func watchdogShouldRecover(visible: Bool, paused: Bool, idle: CFTimeInterval) -> Bool {
        visible && !paused && idle > 1.5
    }

    /// 自测口:直接跑一遍恢复动作,验证它真的作废并重建了合成画面
    func forceRecoveryForTesting() { forceFullRecovery(reason: "自测") }

    /// 自测口:看门狗当前判定的"距上次绘制回调过了多久"
    var secondsSinceLastTickForTesting: CFTimeInterval { CACurrentMediaTime() - lastTickTime }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.window != nil, !self.isHidden,
                  self.window?.isMiniaturized != true,
                  self.window?.occlusionState.contains(.visible) ?? false else { return }
            // isPaused = 有人**主动**停摆(⌘E / 后台省电),那是正常状态,不抢救
            guard !self.isPaused else { return }
            let idle = CACurrentMediaTime() - self.lastTickTime
            guard idle > 1.5 else { return }
            self.forceFullRecovery(reason: String(format: "看门狗:可见却 %.1fs 无绘制回调", idle))
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func installRecoveryObservers() {
        guard recoveryObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        // 系统唤醒 / 显示器唤醒 / 解锁(切回本用户会话)
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            recoveryObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.forceFullRecovery(reason: name.rawValue)
            })
        }
        let nc = NotificationCenter.default
        // 显示器插拔/分辨率变化;窗口换屏;backing scale 变化(换屏必伴随)
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            recoveryObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 换屏/改分辨率还要重算帧率:两台显示器刷新率不同时(如 120Hz 笔记本
                // 屏 + 60Hz 外接屏),窗口拖过去必须跟着变,否则要么浪费要么掉帧
                self?.updateFrameRate()
                self?.forceFullRecovery(reason: name.rawValue)
            })
        }
    }

    deinit {
        for o in activeObservers { NotificationCenter.default.removeObserver(o) }
        for o in recoveryObservers { NotificationCenter.default.removeObserver(o) }
        for o in recoveryObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        watchdog?.invalidate()
    }

    // MARK: - 事件驱动捕获

    /// 全量置脏(resize/滚动/pane 增删/设置变更)
    func scheduleCapture() {
        contentDirty = true
        for s in sources { s.allDirty = true }
        lastActivityTime = CACurrentMediaTime()
    }

    /// 轻量重渲染(选区高亮等覆盖层变化;行缓存有效,成本≈拼接)
    func scheduleRepaint() {
        contentDirty = true
        lastActivityTime = CACurrentMediaTime()
    }

    /// 行缓存全失效 + 重捕获(v1.2:AnsiColor 调色板切换等"全局色变"用)
    func invalidateContentCache() {
        sources.forEach { $0.allDirty = true }
        scheduleCapture()
    }

    // ---- 背景图片(v1.2 #16;v1.5.1 起 CRT 模式也铺)----
    // 加载/特效预处理在 PlainBackground 里键控缓存,两种模式共用同一张成品纹理,
    // 只是上屏路径按当前模式分派:
    //   · 直通模式(colorPassthrough>0.5)→ performCapture 把它当合成层第一笔铺底,
    //     pane 内容以透明底叠上去(v1.2 原路径,一字未动);
    //   · CRT 模式 → buildUniforms 把它绑到 CRT pass 的 texture(4),着色器拿它
    //     替换染色公式里的「屏幕底色」项(见 CRT.metal 的 convertWithChromaBG)。
    // "该不该有图"由 TerminalWindowController 决定(含经典 CRT 组的排除),这里
    // 只负责"有图时走哪条路"。
    private var plainBG: PlainBackground?

    /// 设置接线(applyCRTMode 每次广播都会调;路径/模式/强度没变=纯空转)。
    /// path=nil 即清除(成品纹理顺手释放)
    func setPlainBackground(path: String?, mode: Int, blur: Double, palette: Int) {
        if path != nil && plainBG == nil { plainBG = PlainBackground(ctx: mtl) }
        guard let pb = plainBG else { return }
        if pb.update(path: path, mode: mode, blur: blur, palette: palette) {
            invalidateContentCache()   // 内容纹理清屏透明与否随背景图切换,立即重建
        }
    }

    // 选区变化标记(设/改/清任一;清选区帧靠它强制重算 bloom/burn-in)
    private var selectionDirty = false

    /// 选区变化专用重绘入口(TerminalWindowController 接线)
    func noteSelectionChanged() {
        selectionDirty = true
        scheduleRepaint()
    }

    // ---- 开机自检(v1.2 #10):自检期间合成源换成 BIOS 假屏 ----
    private var bootScreen: BootScreen?
    private var bootTimer: Timer?

    /// 开机自检:显像管亮起后滚 BIOS 文本(仅 AppDelegate 首窗调用;探针不调)
    func startBootScreen(cols: Int, rows: Int) {
        bootScreen = BootScreen(ctx: mtl, cols: cols, rows: rows)
        // 20fps 驱动。时间线推进放 Timer(不放渲染帧):窗口被遮挡/不上屏时
        // 状态机也必须走完,否则自检永不收尾(auto-drive 第二窗实测教训)
        bootTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let boot = self.bootScreen, !boot.finished {
                boot.tick(now: CACurrentMediaTime())
            }
            if self.bootScreen == nil || self.bootScreen!.finished {
                self.bootTimer?.invalidate()
                self.bootTimer = nil
            }
            self.scheduleCapture()
        }
    }

    var bootScreenActive: Bool { bootScreen != nil && !(bootScreen!.finished) }

    // Visual Bell(v1.2 #5)状态:-1 = 无;>0 = 闪屏起点(与渲染时钟同源)
    private(set) var bellFlashStart: CFTimeInterval = -1

    /// 触发一次荧光闪屏(0.18s 亮度脉冲)。短动画不进 animated 模式,
    /// 用几个错峰 repaint 保证脉冲曲线有帧可落(20fps 节流下也够画 3 帧)
    func triggerVisualBell() {
        guard visualBellEnabled else { return }
        bellFlashStart = CACurrentMediaTime()
        scheduleRepaint()
        for delay in [0.05, 0.1, 0.15, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scheduleRepaint()
            }
        }
    }

    /// Visual Bell 开关(设置接线;默认开)
    var visualBellEnabled = true

    /// IME 事件推送:提交/组合变化的同一事件内同步预编辑状态
    func refreshPreeditNow() {
        guard let tv = focusedViewProvider?() else { return }
        let p = currentPreedit(tv)
        if p != lastPreedit {
            lastPreedit = p
            contentDirty = true
            lastActivityTime = CACurrentMediaTime()
        }
    }

    /// 行级脏标记(rangeChanged 事件带行号,按 pane 记账)
    func markDirty(view: EventTerminalView, rows: ClosedRange<Int>) {
        contentDirty = true
        if let s = sources.first(where: { $0.view === view }), !s.allDirty {
            s.dirtyRows.insert(integersIn: rows)
        }
        lastActivityTime = CACurrentMediaTime()
    }

    private func performCapture() {
        guard window != nil, !isHidden, bounds.width > 4, bounds.height > 4,
              let layout = layoutProvider?() else { return }
        let now = CACurrentMediaTime()
        lastCaptureTime = now
        let scale = window?.backingScaleFactor ?? 2.0
        let focused = focusedViewProvider?()

        // 合成画面尺寸 = **drawable 尺寸**,不是 Int(bounds×scale)(2026-07-29
        // 用户实测「CRT 下字体有锯齿、同样两行一清一糊」的根因):MTKView 的
        // drawable 由 CAMetalLayer 按 bounds×contentsScale **四舍五入**得出,而这里
        // 曾用 Int() **截断** —— 窗口逻辑尺寸带小数时(拖拽缩放/恢复旧 frame 常见)
        // 两者差 1 px,CRT 采样的 contentScale 就不再是 1.0,而是 1±1/H:输出行
        // 到源纹理行的映射逐行漂移,屏幕一部分正落 texel 中心(锐利)、另一部分
        // 落在两行之间被 linear 混合(发毛),交界处相邻两行一清一糊。
        // 钉死同尺寸 ⇒ contentScale 恒等 1.0 ⇒ 全屏逐像素 1:1。
        let dsW = Int(drawableSize.width.rounded()), dsH = Int(drawableSize.height.rounded())
        let compW = max(dsW > 0 ? dsW : Int((bounds.width * scale).rounded()), 8)
        let compH = max(dsH > 0 ? dsH : Int((bounds.height * scale).rounded()), 8)
        if sourceTexture == nil || sourceTexture!.width != compW || sourceTexture!.height != compH {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: compW, height: compH,
                                                                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            sourceTexture = mtl.device.makeTexture(descriptor: desc)
            compositeRebuilds += 1
            for s in sources { s.allDirty = true }
        }
        guard let composite = sourceTexture else { return }

        // ---- 开机自检接管(v1.2 #10):BIOS 假屏替代 pane 合成,结束自动切回 ----
        if let boot = bootScreen {
            if boot.finished {
                bootScreen = nil
                sources.forEach { $0.allDirty = true }   // 切回真终端:全量重建
            } else {
                boot.tick(now: now)
                let font = focused?.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                if let tex = boot.render(font: font, scale: scale) {
                    // 落点 = 首 pane 左上(2026-08-07 修复:标题栏透明化+标签栏后,
                    // 画布钉 (0,0) 会顶进红绿灯条/标签栏下面;跟内容同坐标就自动
                    // 让出标题栏、标签栏与 margin,画布尺寸本来就按 pane 网格建)
                    let anchor = layout.panes.first?.rect
                    let bx = ((anchor?.minX ?? 0) * scale).rounded()
                    let by = anchor.map { ((bounds.height - $0.maxY) * scale).rounded() } ?? 0
                    focusedCellPx = boot.cellPx
                    focusedRectPx = CGRect(x: bx, y: by, width: CGFloat(tex.width), height: CGFloat(tex.height))
                    let bootDraws: [(texture: MTLTexture?, viewport: MTLViewport)] =
                        [(tex, MTLViewport(originX: max(0, bx), originY: max(0, by),
                                           width: Double(tex.width), height: Double(tex.height),
                                           znear: 0, zfar: 1))]
                    if let cmd = mtl.queue.makeCommandBuffer() {
                        try? renderer.encodeComposite(into: composite, commandBuffer: cmd, draws: bootDraws)
                        cmd.commit()
                    }
                    return
                }
            }
        }

        let tPerf = perfEnabled ? CACurrentMediaTime() : 0

        // 实质内容变化判定(v1.1 #3 追加):500ms 兜底捕获在完全静止时也会走到
        // 这里 —— 内容纹理没变,辉光模糊/余辉累积重算纯属白做(空闲时每秒两趟
        // 高斯模糊)。判定偏保守:有脏行/全脏/预编辑/选区任一存在都算"变了"。
        // ⚠️ 必须在 pane 循环之前算:循环里会把 dirtyRows 消费清空。
        var contentChanged = lastPreedit != nil || bloomTexture == nil
        // 布局几何变化(2026-08-07 重影修复):标签切换/标签栏出没/边距切换会把
        // pane 落点整体挪位 —— 此时即使一个脏行都没有,合成画面也换了几何,
        // 辉光/余辉必须跟着重算;否则旧几何的辉光(模糊层)叠在新几何的内容上,
        // 全屏一套错位的"重影"(用户实测 bug1/bug2 的根因)
        let layoutSig = layout.panes.map { $0.rect } + [tabStripFrameProvider?() ?? .zero]
        if layoutSig != lastLayoutSignature {
            lastLayoutSignature = layoutSig
            contentChanged = true
            effects?.resetBurnIn()   // 旧几何的余辉不能拖到新几何上(错位重影)
        }
        for s in sources where s.allDirty || !s.dirtyRows.isEmpty { contentChanged = true }
        for (view, _) in layout.panes where view.selectionSnapshot != nil { contentChanged = true }
        // 选区"刚刚消失"的那一帧也算变化(2026-07-28 用户实测):只看"现在有
        // 选区"会漏掉取消帧 —— 内容纹理重建了,但 bloom 跳过重算,旧辉光里
        // 大亮块的光晕留在屏上成"阴影",直到下次内容变化才消失
        if selectionDirty {
            contentChanged = true
            selectionDirty = false
        }

        var draws: [(texture: MTLTexture?, viewport: MTLViewport)] = []

        // 背景图(v1.2 #16):**合成层路径只属于直通模式**;有图 → pane 内容透明清屏。
        // CRT 模式绝不能走这里 —— 图一旦进了内容纹理就成了"内容",会被荧光染色、
        // 吃辉光/白热化/余辉拖尾,整张图跟着发光拖影,文字也就没法看了。CRT 模式
        // 走 buildUniforms 那条 texture(4) 屏幕底图路径。
        let plainBGTex = uniforms.colorPassthrough > 0.5 ? plainBG?.texture : nil

        for (view, rect) in layout.panes {
            guard let src = sources.first(where: { $0.view === view }) else { continue }
            let terminal = view.getTerminal()
            var preedit: ContentRenderer.Preedit?
            if view === focused, let text = lastPreedit {
                let cur = terminal.getCursorLocation()
                preedit = .init(text: text, col: cur.x, row: cur.y)
            }
            var selection: ContentRenderer.Selection?
            if let snap = view.selectionSnapshot {
                selection = .init(start: snap.start, end: snap.end, yDisp: terminal.buffer.yDisp)
            }
            // ⌘悬停链接高亮(v1.1 #5):buffer 绝对行 → 视口行(滚出屏的丢弃)
            var linkHighlight: [(row: Int, range: Range<Int>)]?
            if let snap = view.linkHighlightSnapshot {
                let yDisp = terminal.buffer.yDisp
                let mapped = snap.map { (row: $0.row - yDisp, range: $0.range) }
                    .filter { $0.row >= 0 && $0.row < terminal.rows }
                linkHighlight = mapped.isEmpty ? nil : mapped
            }
            // 失败命令 ✗ 标记(v1.2 #3):视口内 exit≠0 的提示符行左缘红条
            let failedRows = view.failedCommandViewportRows()
            guard let tex = src.content.render(terminal: terminal, font: view.font, scale: scale,
                                               preedit: preedit, selection: selection,
                                               linkHighlight: linkHighlight,
                                               failedRows: failedRows.isEmpty ? nil : failedRows,
                                               transparentDefaultBg: plainBGTex != nil,
                                               dirtyRows: src.allDirty ? nil : src.dirtyRows,
                                               wait: false) else { continue }
            src.dirtyRows.removeAll()
            src.allDirty = false

            // pane 内容 1:1 摆放(左上锚定,不拉伸;余量在 CRT 前保持黑)。
            // 落点取整到物理像素:margin 是逻辑点小数(如 0.15 → 内缩 6.85pt →
            // 13.7px),不取整则整块内容压在半像素上 —— 字形边缘与像素网格错位,
            // 观感发虚(同 2026-07-29 锯齿事故的次因;取整后字形逐像素对齐)
            let topY = ((bounds.height - rect.maxY) * scale).rounded()
            let leftX = (rect.minX * scale).rounded()
            draws.append((tex, MTLViewport(originX: leftX, originY: topY,
                                           width: Double(tex.width), height: Double(tex.height),
                                           znear: 0, zfar: 1)))
            if view === focused {
                focusedCellPx = src.content.cellPx
                focusedRectPx = CGRect(x: leftX, y: topY,
                                       width: (rect.width * scale).rounded(),
                                       height: (rect.height * scale).rounded())
            }
        }

        // 荧光分割线(≥2 逻辑 px,内容空间纯白 → CRT 染成荧光色 + 吃辉光)。
        // 样式:0 实线整条;1 虚线段(10pt 段 / 7pt 空);2 点线(方点 / 5pt 空)
        for d in layout.dividers {
            let minThick = 2.0 * scale
            var w = d.width * scale, h = d.height * scale
            var x = d.minX * scale, y = (bounds.height - d.maxY) * scale
            if w < minThick { x -= (minThick - w) / 2; w = minThick }
            if h < minThick { y -= (minThick - h) / 2; h = minThick }
            // 同样取整到物理像素:半像素上的分割线会被 CRT 采样糊成两条淡线
            x = x.rounded(); y = y.rounded(); w = w.rounded(); h = h.rounded()

            func line(_ lx: Double, _ ly: Double, _ lw: Double, _ lh: Double) {
                draws.append((nil, MTLViewport(originX: lx, originY: ly, width: lw, height: lh,
                                               znear: 0, zfar: 1)))
            }
            if dividerStyle == 0 {
                line(x, y, w, h)
            } else {
                let horizontal = w >= h
                let thick = horizontal ? h : w
                let length = horizontal ? w : h
                let seg = dividerStyle == 1 ? 10.0 * scale : thick
                let gap = dividerStyle == 1 ? 7.0 * scale : 5.0 * scale
                var offset = 0.0
                while offset < length {
                    let s = min(seg, length - offset)
                    if horizontal {
                        line(x + offset, y, s, h)
                    } else {
                        line(x, y + offset, w, s)
                    }
                    offset += seg + gap
                }
            }
        }

        // CRT 盒绘标签条(2026-08-06):荧光屏顶部,与内容同过 CRT ——
        // 吃染色/扫描线/辉光,跟着屏幕鼓弧度、被机壳裁切(用户点名要的"屏内"质感)
        if let strip = tabStrip, let rect = tabStripFrameProvider?(),
           let f = focused ?? sources.first?.view,
           let stripTex = strip.render(font: f.font, scale: scale) {
            let sx = (rect.minX * scale).rounded()
            let sy = ((bounds.height - rect.maxY) * scale).rounded()
            draws.append((stripTex, MTLViewport(originX: max(0, sx), originY: max(0, sy),
                                                width: Double(stripTex.width),
                                                height: Double(stripTex.height),
                                                znear: 0, zfar: 1)))
        }

        // OSD 面板(v1.2 #14):画面正中,和内容一起过 CRT(真显示器 OSD 的质感)
        if let osd = osdController, osd.visible, let f = focused ?? sources.first?.view,
           let osdTex = osd.render(font: f.font, scale: scale) {
            let ox = ((Double(compW) - Double(osdTex.width)) / 2).rounded()
            let oy = ((Double(compH) - Double(osdTex.height)) / 2).rounded()
            draws.append((osdTex, MTLViewport(originX: max(0, ox), originY: max(0, oy),
                                              width: Double(osdTex.width),
                                              height: Double(osdTex.height),
                                              znear: 0, zfar: 1)))
        }

        // 粘贴确认面板(v1.3 改版):OSD 同款合成路径,画面正中
        if let pg = pasteGuardController, pg.visible, let f = focused ?? sources.first?.view,
           let pgTex = pg.render(font: f.font, scale: scale) {
            let px = ((Double(compW) - Double(pgTex.width)) / 2).rounded()
            let py = ((Double(compH) - Double(pgTex.height)) / 2).rounded()
            draws.append((pgTex, MTLViewport(originX: max(0, px), originY: max(0, py),
                                             width: Double(pgTex.width),
                                             height: Double(pgTex.height),
                                             znear: 0, zfar: 1)))
        }

        // 服务器选单(v1.3 SSH):OSD 同款合成路径,画面正中
        if let sp = serverPickerController, sp.visible, let f = focused ?? sources.first?.view,
           let spTex = sp.render(font: f.font, scale: scale) {
            let sx = ((Double(compW) - Double(spTex.width)) / 2).rounded()
            let sy = ((Double(compH) - Double(spTex.height)) / 2).rounded()
            draws.append((spTex, MTLViewport(originX: max(0, sx), originY: max(0, sy),
                                             width: Double(spTex.width),
                                             height: Double(spTex.height),
                                             znear: 0, zfar: 1)))
        }

        // 取证口(2026-08-07 重影排查):打印本次合成的每一笔(探针置位)
        if dumpDrawsOnNextCapture {
            dumpDrawsOnNextCapture = false
            for (i, d) in draws.enumerated() {
                let v = d.viewport
                FileHandle.standardError.write(Data(
                    "  [draw \(i)] tex=\(d.texture.map { "\($0.width)x\($0.height)" } ?? "solid") viewport=(\(v.originX),\(v.originY) \(v.width)x\(v.height))\n".utf8))
            }
        }

        guard let cmd = mtl.queue.makeCommandBuffer() else { return }
        do {
            // 直通模式:合成层底色 = 用户背景色(padding/余量融入背景);CRT = 黑
            let clear = uniforms.colorPassthrough > 0.5
                ? MTLClearColor(red: Double(uniforms.backgroundColor.x),
                                green: Double(uniforms.backgroundColor.y),
                                blue: Double(uniforms.backgroundColor.z), alpha: 1)
                : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            try renderer.encodeComposite(into: composite, commandBuffer: cmd, draws: draws,
                                         clearColor: clear, background: plainBGTex)
        } catch {
            FileHandle.standardError.write(Data("composite: \(error)\n".utf8))
            return
        }
        cmd.commit()

        if perfEnabled {
            let ms = (CACurrentMediaTime() - tPerf) * 1000
            perfEMA = perfEMA == 0 ? ms : perfEMA * 0.95 + ms * 0.05
            perfCount += 1
            if perfCount % 120 == 0 {
                FileHandle.standardError.write(Data(String(format: "[perf] content build EMA %.3f ms\n", perfEMA).utf8))
            }
        }

        // M1b 派生纹理:内容更新才重算(与原版 onImagePainted 驱动语义一致;
        // contentChanged=false 的兜底捕获跳过 —— 结果必然与上次相同)
        if let fx = effects, contentChanged {
            // 机壳反射带也吃辉光纹理(屏幕光映照机壳),故机壳开着就要算
            if uniforms.bloomAmount > 0 || (uniforms.frameOn > 0.5 && uniforms.frameShininess > 0) {
                bloomTexture = fx.bloom(from: composite, radiusPx: Float(40 * scale), wait: false,
                                        style: uniforms.bloomStyle > 0.5 ? 1 : 0,
                                        shape: uniforms.bloomShape > 0.5 ? 1 : 0)
            }
            if uniforms.burnIn > 0 {
                // 光标拖尾(v1.1 #6 三轮):GPU 参数光标不在内容纹理里,余辉缓冲
                // 看不见它 → 把光标块叠进累积输入。DECTCEM 藏光标/无焦点时不叠。
                var cRect = SIMD4<Float>.zero
                if let tv = focused, let r = cursorRectInComposite(tv: tv),
                   caretMirror.map({ $0.superview != nil }) ?? true {
                    cRect = r
                }
                _ = fx.accumulateBurnIn(content: composite, time: Float(now - t0),
                                        burnInTime: uniforms.burnInTime,
                                        cursorRect: cRect, cursorStyle: cursorStyle, wait: false)
            }
        }
    }

    /// 焦点光标块几何(合成画面 UV,原点左上;nil = 位置无效)。
    /// ⚠️ 与 buildUniforms 的光标段同源同公式(focusedCellPx/focusedRectPx/宽字符
    /// 双格判定)—— 改任一处必同步另一处,否则拖尾会跟实时光标错格。
    private func cursorRectInComposite(tv: EventTerminalView) -> SIMD4<Float>? {
        let terminal = tv.getTerminal()
        let cursor = terminal.getCursorLocation()
        guard let src = sourceTexture, terminal.cols > 0, terminal.rows > 0,
              cursor.y >= 0, cursor.y < terminal.rows, focusedCellPx.w > 0 else { return nil }
        let compW = Float(src.width), compH = Float(src.height)
        let cellW = Float(focusedCellPx.w) / compW
        let cellH = Float(focusedCellPx.h) / compH
        var cw = cellW
        if cursor.x < terminal.cols, let line = terminal.getLine(row: cursor.y),
           line[cursor.x].width == 2 {
            cw = cellW * 2
        }
        return .init(Float(focusedRectPx.minX) / compW + Float(cursor.x) * cellW,
                     Float(focusedRectPx.minY) / compH + Float(cursor.y) * cellH,
                     cw, cellH)
    }

    /// 热重载着色器;失败返回错误描述(调用方弹窗),保留旧管线继续跑
    func reloadShaders() -> String? {
        renderer.invalidatePipelines()
        for s in sources { s.content.invalidatePipelines() }
        do {
            _ = try mtl.library(named: "CRT")
            _ = try mtl.library(named: "Passthrough")
            _ = try mtl.library(named: "TextGrid")
            _ = try mtl.library(named: "Bloom")   // v1.4:辉光两种风格都在这个库里,调 halation 要能热重载
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func applyVisibility() {
        isHidden = userHidden
    }

    /// 当前 IME 预编辑文本(走 NSTextInputClient 公开接口)
    private func currentPreedit(_ tv: TerminalView) -> String? {
        guard tv.hasMarkedText() else { return nil }
        let r = tv.markedRange()
        guard r.location != NSNotFound, r.length > 0 else { return nil }
        return tv.attributedSubstring(forProposedRange: r, actualRange: nil)?.string
    }

    /// 组装本帧 uniforms(屏显 renderTick 与自测 dumpFrame 共用,保证同源)
    private func buildUniforms(tv: EventTerminalView, dw: Int, dh: Int,
                               now: CFTimeInterval, forceBlinkOn: Bool, smooth: Bool = true) -> CRTUniforms {
        var u = uniforms
        u.time = Float(now - t0)
        let terminal = tv.getTerminal()
        let backingF = Float(window?.backingScaleFactor ?? 2.0)
        // 屏幕级虚拟分辨率(pitch 从焦点字体推导,覆盖整块合成画面)
        u.virtualResolution = CRTPass.virtualResolutionScreen(widthPx: dw, heightPx: dh,
                                                              cellPx: focusedCellPx, scale: backingF)
        u.rasterizationIntensity = CRTPass.rasterizationIntensity(drawableH: dh, vresY: u.virtualResolution.y,
                                                                  scale: backingF)
        u.scaleNoiseSize = .init(Float(dw) * 0.75 / 512.0, Float(dh) * 0.75 / 512.0)
        if let src = sourceTexture {
            u.contentScale = .init(Float(dw) / Float(src.width), Float(dh) / Float(src.height))
            u.rgbShift = uniforms.rgbShift * 4.0 / Float(src.width)
            // YETERM_DEBUG_METRICS=1:首帧打印一次全套几何(bounds/scale/drawable/
            // 合成/cell/网格/pane 落点/contentScale)。2026-07-29 锯齿事故就是靠它
            // 定位的 —— contentScale 不等于 1.0 即"文字被非整数重采样"的铁证
            if ProcessInfo.processInfo.environment["YETERM_DEBUG_METRICS"] != nil, !metricsLogged {
                metricsLogged = true
                FileHandle.standardError.write(Data("""
                [metrics] bounds=\(bounds.size) scale=\(backingF) drawable=\(dw)x\(dh) \
                comp=\(src.width)x\(src.height) cell=\(focusedCellPx) grid=\(terminal.cols)x\(terminal.rows) \
                paneRect=\(focusedRectPx) contentScale=\(Double(dw)/Double(src.width)),\(Double(dh)/Double(src.height))

                """.utf8))
            }
        }
        // 合成画面已含留白(窗口级内缩),CRT 侧不再平移
        u.contentOffset = .zero
        u.viewportSize = .init(Float(dw), Float(dh))
        // 机壳最小带(2026-08-07 用户需求):机壳开启时,屏幕玻璃区上下各内缩出
        // 一条 = 标题栏高度的机壳带 —— 红绿灯/标题落在带的垂直正中(带高=标题栏
        // 高,系统标题文字在标题栏内天然居中)。上下对称(用户裁决);左右不动。
        // 全屏无标题栏 → 0;机壳关 → 0(屏幕充满窗口 = 1.2 原语义)。
        // 换算:屏幕上缘落在窗口 uv=t 处需 inset=t/(1-2t)(padding 变换的解),
        // t = 标题栏高/窗口高。
        if u.frameOn > 0.5, let w = window {
            let t = Float(max(0, bounds.height - w.contentLayoutRect.height) / max(bounds.height, 1))
            u.screenInset = .init(0, t / max(1 - 2 * t, 0.5))
        } else {
            u.screenInset = .zero
        }
        u.bloomPad = bloomTexture != nil ? (effects?.bloomPadUV ?? .zero) : .zero
        u.powerOnProgress = currentPowerProgress(now: now)   // 开机/关机动画(稳态=1)

        // 背景图片(v1.5.1):CRT 模式把成品纹理当「屏幕底图」绑到 texture(4)。
        // 直通模式不进这条路(图已由合成层铺好),故按 colorPassthrough 分派。
        // `effects != nil` 是必要条件:extras 数组靠 blackTexture 兜住空位来维持
        // 索引对齐(noise=1/bloom=2/burnIn=3/bgImage=4),没有它数组会塌陷错位。
        if u.colorPassthrough <= 0.5, effects != nil,
           let bg = plainBG?.texture, bg.width > 0, bg.height > 0 {
            u.bgImageOn = 1
            // aspect-fill:与合成层 plain_bg_fill_fragment 同一套公式(按比例盖满画面、
            // 长出来的边裁掉,不拉伸)—— 两条路径换着走时构图不跳。
            let targetAspect = Float(dw) / Float(max(dh, 1))
            let imgAspect = Float(bg.width) / Float(max(bg.height, 1))
            u.bgImageUVScale = .init(min(1, targetAspect / imgAspect),
                                     min(1, imgAspect / targetAspect))
        } else {
            u.bgImageOn = 0
        }

        // Visual Bell(v1.2 #5):bell 后 0.18s 内亮度短脉冲(sin 半波包络,峰值 +45%),
        // 复古演绎"荧光屏闪一下";clamp 到 uniforms 合法域,只动本帧拷贝不污染基线
        if bellFlashStart > 0 {
            let bt = now - bellFlashStart
            if bt < 0.18 {
                let pulse = Float(sin(bt / 0.18 * .pi)) * 0.45
                u.brightness = min(1.5, u.brightness * (1 + pulse))
            }
        }
        // 换台(v1.2 #12):闪断期间雪花噪点+水平失步临时抬高(sin 包络峰在中点)——
        // "信号断开重连"的老电视质感;只动本帧拷贝不污染基线
        if channelSwitchStart > 0 {
            let ct = now - channelSwitchStart
            let total = channelCollapse + channelExpand
            if ct < total {
                let env = Float(sin(ct / total * .pi))
                u.staticNoise = max(u.staticNoise, 0.45 * env)
                u.horizontalSyncStrength = max(u.horizontalSyncStrength, 0.18 * env)
            }
        }
        // 消磁(v1.2 #13):指数衰减包络驱动波纹(shader)+ 色差瞬时飙大 + 轻微晃动;
        // 同样只动本帧拷贝
        if degaussStart > 0 {
            let dt = now - degaussStart
            if dt < degaussDuration {
                let env = Float(exp(-3.5 * dt / degaussDuration))
                u.degauss = env
                u.rgbShift += env * 10.0 / Float(max(dw, 1))   // 色差飙 ~10px 再衰减
                u.jitter = max(u.jitter, 0.35 * env)
            } else {
                degaussStart = -1
            }
        }

        // 光标(焦点 pane;UV 映射进合成画面):显隐镜像 SwiftTerm caretView
        let lastActivity = max(lastInputTime, lastActivityTime)
        let idle = now - lastActivity
        let blinkOn = forceBlinkOn || !cursorBlinks || idle < 1.0
            || idle.truncatingRemainder(dividingBy: 1.0) < 0.6
        if let found = tv.subviews.first(where: { String(describing: type(of: $0)).contains("Caret") }) {
            caretMirror = found
        }
        let caretVisible = caretMirror.map { $0.superview != nil } ?? true
        let cursor = terminal.getCursorLocation()
        let compW = Float(sourceTexture?.width ?? dw)
        let compH = Float(sourceTexture?.height ?? dh)
        if blinkOn, caretVisible, lastPreedit == nil, bootScreen == nil,   // 自检屏无真光标
           terminal.cols > 0, terminal.rows > 0,
           cursor.y >= 0, cursor.y < terminal.rows, focusedCellPx.w > 0, compW > 0, compH > 0 {
            let cellW = Float(focusedCellPx.w) / compW      // cell 尺寸(合成 UV)
            let cellH = Float(focusedCellPx.h) / compH
            var cw = cellW
            if cursor.x < terminal.cols, let line = terminal.getLine(row: cursor.y),
               line[cursor.x].width == 2 {
                cw = cellW * 2
            }
            var pos = SIMD2<Float>(Float(focusedRectPx.minX) / compW + Float(cursor.x) * cellW,
                                   Float(focusedRectPx.minY) / compH + Float(cursor.y) * cellH)
            if smooth {
                // 指数逼近(τ≈35ms):逐格跳变揉成连续滑移;跨行/远跳直接落位
                if var cur = smoothCursorUV {
                    let delta = pos - cur
                    if abs(delta.x) > 4 * cellW || abs(delta.y) > 0.5 * cellH {
                        cur = pos
                    } else {
                        cur += delta * 0.38
                        if abs(pos.x - cur.x) < cellW * 0.02 { cur.x = pos.x }
                        if abs(pos.y - cur.y) < cellH * 0.02 { cur.y = pos.y }
                    }
                    smoothCursorUV = cur
                    pos = cur
                } else {
                    smoothCursorUV = pos
                }
            }
            u.cursorRectUV = .init(pos.x, pos.y, cw, cellH)
            u.cursorOn = 1
            u.cursorStyle = cursorStyle
        } else {
            smoothCursorUV = nil
        }
        return u
    }

    /// 自测:把「与屏幕同源」的一帧渲染导出 PNG(--auto-drive 用)
    /// 与屏幕同源渲染一帧(v1.2 #7 拆出通用取帧口)。
    /// `live=false`:探针/截图用,强制稳态+光标恒亮(确定性);
    /// `live=true`:录 GIF 用,保留动画相位/光标闪烁/噪点等真实动态。
    func frameImage(live: Bool = false) -> CGImage? {
        guard let tv = focusedViewProvider?() ?? sources.first?.view else { return nil }
        performCapture()
        guard let src = sourceTexture else { return nil }
        let dw = src.width, dh = src.height
        var u = buildUniforms(tv: tv, dw: dw, dh: dh, now: CACurrentMediaTime(),
                              forceBlinkOn: !live, smooth: live)
        if !live {
            u.powerOnProgress = 1    // 自测截图永远取稳态(确定性;动画由 GUI 目检)
        }
        u.burnInLastUpdate = effects.map { $0.burnInLastUpdate } ?? 0
        // 取证口(2026-08-07 背景图染色排查):导出帧的实际参数
        if ProcessInfo.processInfo.environment["YETERM_DEBUG_BGIMG"] != nil {
            FileHandle.standardError.write(Data(
                "[bgimg] on=\(u.bgImageOn) chroma=\(u.bgImageChroma) inset=\(u.screenInset) uv=\(u.bgImageUVScale) pass=\(u.colorPassthrough) tex=\(plainBG?.texture.map { "\($0.width)x\($0.height)" } ?? "nil")\n".utf8))
        }
        let black = effects?.blackTexture
        // texture(1..4) = 噪点 / 辉光 / 余辉 / 背景图。空位一律用 blackTexture 占住
        // 维持索引对齐(compactMap 会让数组塌陷 → 后面的纹理全绑错位)
        let extras: [MTLTexture] = [
            noiseTexture ?? black,
            bloomTexture ?? black,
            (u.burnIn > 0 ? effects?.currentBurnIn : nil) ?? black,
            (u.bgImageOn > 0.5 ? plainBG?.texture : nil) ?? black,
        ].compactMap { $0 }
        do {
            let out = try withUnsafeBytes(of: &u) { p in
                try renderer.renderFullscreen(library: "CRT",
                                              fragment: "crt_fragment",
                                              source: src,
                                              uniforms: p,
                                              extraTextures: extras,
                                              outWidth: dw, outHeight: dh)
            }
            return renderer.readback(out)
        } catch {
            FileHandle.standardError.write(Data("frameImage: \(error)\n".utf8))
            return nil
        }
    }

    /// 取证口(2026-08-07 重影排查):下一次捕获把 draws 逐笔打到 stderr
    var dumpDrawsOnNextCapture = false

    /// 取证口(2026-08-07 重影排查):导出**原始合成纹理**(CRT 处理前)。
    /// 残影在这里 = 捕获/落点问题;不在 = 辉光/余辉等派生层问题。
    func dumpComposite(to path: String) -> Bool {
        performCapture()
        guard let src = sourceTexture, let img = renderer.readback(src) else { return false }
        return (try? PNGWriter.write(img, to: path)) != nil
    }

    func dumpFrame(to path: String) -> Bool {
        guard let img = frameImage() else { return false }
        do {
            try PNGWriter.write(img, to: path)
            return true
        } catch {
            FileHandle.standardError.write(Data("dumpFrame: \(error)\n".utf8))
            return false
        }
    }

    // MARK: - GPU 帧(60fps:动画 + 光标)

    private var metricsLogged = false

    private func renderTick() {
        // 渲染循环心跳(v1.4 事故修复):看门狗据此判断绘制回调是否还在来。
        // **必须在所有 guard 之前** —— 被遮挡/隐藏而早退也算"回调还活着",
        // 只有 display link 本身死了才该触发恢复。
        lastTickTime = CACurrentMediaTime()
        guard let tv = focusedViewProvider?() ?? sources.first?.view,
              tv.window != nil,
              window?.isMiniaturized != true,
              window?.occlusionState.contains(.visible) ?? true else { return }

        // IME 预编辑轮询兜底(事件推送为主)
        let preedit = currentPreedit(tv)
        if preedit != lastPreedit {
            lastPreedit = preedit
            contentDirty = true
        }
        guard !isHidden else { return }

        let now = CACurrentMediaTime()

        let didCapture = contentDirty || sourceTexture == nil || (now - lastCaptureTime) > 0.5
        if didCapture {
            contentDirty = false
            performCapture()
        }
        let dw = drawableSize.width > 0 ? Int(drawableSize.width) : 1
        let dh = drawableSize.height > 0 ? Int(drawableSize.height) : 1

        ensureCompositeMatchesDrawable()
        guard let src = sourceTexture else { return }

        // 首帧即将上屏 → 开机动画正式开表(此前挂起输出全黑;见 playPowerOn)
        if powerOnPending {
            powerOnPending = false
            powerAnimReverse = false
            powerAnimStart = now
        }

        var u = buildUniforms(tv: tv, dw: dw, dh: dh, now: now, forceBlinkOn: false)

        // 关机动画放完 → 通知窗口控制器真正关窗(回调只发一次)。
        // async 派发:此刻正处在 MTKView 的 draw 回调栈内,同步 close 会在
        // 绘制中途拆视图 —— 挪到下一个 runloop 周期再关。
        if powerAnimReverse, powerAnimStart >= 0, now - powerAnimStart >= powerOffDuration {
            powerAnimStart = -1
            powerAnimReverse = false
            if let done = powerOffCompletion {
                powerOffCompletion = nil
                DispatchQueue.main.async { done() }
            }
        }

        // 跳帧决策(内容未变 + 光标状态未变时):
        //   ① 无动画特效 → 完全不出帧(静态跳帧,v1.0 既有);
        //   ② 只有 time 动画(噪点/闪烁/亮线/抖动/余辉)→ ~20fps 节流出帧
        //      (crterm effectsFrameSkip=3 语义);开关机动画期间不节流(塌缩要顺滑)。
        // 余辉只在"还在衰减"时算动画:最近一次累积起 1/burnInTime 秒后 shader 里
        // blurDecay 已 clamp 到 1、画面不再变 —— 继续出帧纯属白做(v1.1 #3 追加)。
        let burnDecaying = uniforms.burnIn > 0 && effects.map {
            Float(now - t0) - $0.burnInLastUpdate < 1.0 / max(uniforms.burnInTime, 0.001) + 0.25
        } ?? false
        let animated = powerAnimStart >= 0 || uniforms.staticNoise > 0 || uniforms.flickering > 0
            || uniforms.glowingLine > 0 || burnDecaying
            || uniforms.jitter > 0 || uniforms.horizontalSyncStrength > 0
        if !didCapture,
           u.cursorRectUV == lastPresentedCursor, u.cursorOn == lastPresentedCursorOn {
            if !animated { return }
            if powerAnimStart < 0, now - lastAnimFrameTime < animFrameInterval { return }
        }
        lastAnimFrameTime = now

        // 在途帧限流:已有 2 帧未上屏就跳过(丢旧不排队)
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable,
              let cmd = mtl.queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        if perfEnabled {
            // 【学】cb.gpuEndTime - gpuStartTime 是 Metal 报告的 GPU 真实执行时长
            //      (不含排队等待)—— 比 CPU 侧计时准确得多,是调优的第一手数据。
            cmd.addCompletedHandler { [weak self, inFlight] cb in
                inFlight.signal()
                let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                DispatchQueue.main.async { self?.recordGPUTime(ms) }
            }
        } else {
            cmd.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        }

        u.burnInLastUpdate = effects.map { $0.burnInLastUpdate } ?? 0
        let black = effects?.blackTexture
        // texture(1..4) = 噪点 / 辉光 / 余辉 / 背景图。空位一律用 blackTexture 占住
        // 维持索引对齐(compactMap 会让数组塌陷 → 后面的纹理全绑错位)
        let extras: [MTLTexture] = [
            noiseTexture ?? black,
            bloomTexture ?? black,
            (u.burnIn > 0 ? effects?.currentBurnIn : nil) ?? black,
            (u.bgImageOn > 0.5 ? plainBG?.texture : nil) ?? black,
        ].compactMap { $0 }
        do {
            try withUnsafeBytes(of: &u) { p in
                try renderer.encode(into: drawable.texture,
                                    commandBuffer: cmd,
                                    library: "CRT",
                                    fragment: "crt_fragment",
                                    source: src,
                                    uniforms: p,
                                    extraTextures: extras)
            }
        } catch {
            FileHandle.standardError.write(Data("overlay 渲染失败,暂停特效: \(error)\n".utf8))
            inFlight.signal()
            stop()
            userHidden = true
            return
        }
        cmd.present(drawable)
        cmd.commit()
        lastPresentedCursor = u.cursorRectUV
        lastPresentedCursorOn = u.cursorOn
    }
}

// MARK: - MTKViewDelegate(display link 驱动,垂直同步锁相)
extension MetalOverlayView: MTKViewDelegate {
    func draw(in view: MTKView) {
        renderTick()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
