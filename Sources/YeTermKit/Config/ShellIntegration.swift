// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— Shell 集成的"安装器"(v1.2 #3)
//
// 这个文件:命令导航要 shell 配合报幕(见 CommandMarks 导读),所以要往
//   用户的 ~/.zshrc 里装一小段钩子。这里管三件事:
//   ① 生成集成脚本(写到 app 自己的数据目录,升级时覆盖即最新版);
//   ② 一键安装 = 往 ~/.zshrc 追加一行 source(幂等:装过就不再加);
//   ③ 状态查询(设置页/菜单显示"已安装/未安装")。
//   脚本开头有双保险:只在 YeTerm 里生效(认 TERM_PROGRAM 环境变量),
//   用户在 iTerm2/Terminal 里打开同一个 zshrc 不受任何影响。
//
// 语法看点:多行字符串 """...""" 里 \(变量) 会插值、\\e 转义 ——
//   写 shell 脚本这类"代码里嵌代码"时要小心两层转义(和 Java 拼 SQL 一个坑)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

/// zsh 集成脚本的生成/安装/状态。marker 行是幂等与卸载的锚。
public enum ShellIntegration {
    static let scriptPath = NSHomeDirectory()
        + "/Library/Application Support/YeTerm/shell-integration.zsh"
    static let zshrcPath = NSHomeDirectory() + "/.zshrc"
    static let marker = "# YeTerm shell 集成(命令导航)"

    /// 集成脚本正文:precmd 报"上一条结束(带退出码)+ 新提示符";preexec 报"命令开跑"。
    /// `$?` 必须最先捕获(任何命令都会覆盖它)。
    static let script = """
    \(marker) —— 由 YeTerm 自动生成,升级时会覆盖此文件
    # 只在 YeTerm 里生效;其它终端(iTerm2 等)有各自的集成,互不打扰
    [[ "$TERM_PROGRAM" == "YeTerm" ]] || return 0
    # 版本感知守卫(v1.3 勘差):同版本重复 source 幂等跳过;**版本不同放行**
    # —— 否则已开会话手动 source ~/.zshrc 升级新脚本会被旧守卫拦死,
    # 「刷新脚本」对存量会话永远无效
    [[ "$_YETERM_INTEGRATION" == "16" ]] && return 0
    _YETERM_INTEGRATION=16

    _yeterm_precmd() {
        local code=$?
        printf '\\e]133;D;%s\\a\\e]133;A\\a' "$code"
        # 启动路径的主题手术推迟到这里(2026-08-06 勘差:zshrc 末尾直接做
        # p10k teardown 会撞上 p10k instant prompt 未收尾 —— zle 被楔死成
        # 「回显不执行」,auto-drive 首窗 100% 复现;precmd 是本脚本历次勘差
        # 认证过的唯一安全手术时点,与 OSC 7777 握手同时机)。boot 模式走
        # case 静态应用、不 exec(exec 只认 precmd 模式,防启动无限重启)
        if [[ -n "${_yeterm_boot_pending-}" ]]; then
          unset _yeterm_boot_pending
          _yeterm_apply_prompt boot
        fi
        # 热切握手(OSC 7777)在**首个 precmd** 发(v1.3 勘差:zshrc 加载期间
        # printf 会撞 p10k instant prompt 的"加载期禁输出"—— 触发警告刷屏
        # 甚至吞掉握手;precmd 时 instant prompt 已收尾,输出安全)
        if [[ -z "${_yeterm_ready_sent-}" ]]; then
          _yeterm_ready_sent=1
          printf '\\e]7777;prompt-ready-2\\a'
        fi
        # 提示符主题保底同步(v1.3 防弹三层之三):信号丢失/trap 失效时,
        # 每个提示符周期比对状态文件,变了就跟上(值没变时是一次字符串比较,零开销)
        _yeterm_apply_prompt precmd
        # zle -F 注册保活:p10k teardown 会按它的 zle 快照复原、拆掉我们的
        # 异步回调(handler 内补挂也会被返回时的复原覆盖)—— precmd 是手术
        # 之外的安全时点,每周期幂等补挂一行
        [[ -n "${_yeterm_fd-}" ]] && zle -F "$_yeterm_fd" _yeterm_zle_notify 2>/dev/null
    }
    _yeterm_preexec() {
        printf '\\e]133;C\\a'
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _yeterm_precmd
    add-zsh-hook preexec _yeterm_preexec

    # —— 提示符主题(v1.3,支持热切换):YeTerm 把当前主题写进状态文件,
    #    启动时应用一次;设置/预设切换时 YeTerm 发 SIGUSR1,本会话原地重applied
    #    (zle reset-prompt 只重画提示符,不动正在输入的内容)。
    #    只影响 YeTerm 里的 shell;不改 ZSH_THEME、不动其它终端。
    _yeterm_prompt_file="$HOME/Library/Application Support/YeTerm/prompt-theme"
    _yeterm_prompt_last=""
    # 用户 zshrc 的原始主题(我们介入前;omz theme use 会改写 ZSH_THEME,
    # 必须在此刻快照 —— "不干预"恢复的就是它)
    _yeterm_orig_theme="${ZSH_THEME-}"
    _yeterm_apply_prompt() {
      # ⚠️ 不用 localoptions(2026-07-29 用户实测泄漏勘差):它会在本函数返回时
      # 把 p10k setup 在函数内设置的全局 prompt 展开选项一并撤销 —— p10k 在
      # 错误的展开环境下渲染,agnoster 等主题的 %K{...} 原始转义字面上屏。
      # 防错策略改为:各分支显式声明所需选项(全局生效)+ 全程 2>/dev/null;
      # 未设变量一律 ${var-} 安全展开(no_unset 在 trap 上下文致命,不用)
      local mode="${1-}"
      local t=""
      [[ -f "$_yeterm_prompt_file" ]] && t="$(<"$_yeterm_prompt_file")"
      [[ -z "$t" ]] && t="${YETERM_PROMPT-}"     # 老机制环境变量兜底
      [[ "$t" == "$_yeterm_prompt_last" ]] && return 0   # 值没变不重复折腾
      print -r -- "$(date +%H:%M:%S) [zsh $$] apply \"$_yeterm_prompt_last\" -> \"$t\" (mode=$mode)" >> "$HOME/Library/Application Support/YeTerm/prompt-debug.log" 2>/dev/null
      # ── 热切换的工程止损(2026-07-29 终审):涉及 p10k / omz 主题的在线切换,
      # 卸载/重装/挂起/选项钉死四条路线全部实测状态腐化(p10k 深度侵入 zsh,
      # 内部快照不可控)—— 改为 **exec zsh 会话干净重载**:进程级重启后新
      # shell 按状态文件从零加载,数学上无残留。复古提示符之间仍零延迟轻切。
      # 仅 hot 路径 exec(启动路径静态加载,防无限重启);历史/目录保留
      # exec 只在 precmd 干净上下文执行(zle 回调里 exec 会把终端带进坏状态,
      # 实测新 shell 起不来)—— zle 路径由 handler send-break 促成 precmd
      if [[ "$mode" == precmd && ! ( "$t" == retro:* && "$_yeterm_prompt_last" == retro:* ) ]]; then
        print -r -- "$(date +%H:%M:%S) [zsh $$] exec 重载 -> $t" >> "$HOME/Library/Application Support/YeTerm/prompt-debug.log" 2>/dev/null
        rm -f "$_yeterm_fifo" 2>/dev/null   # exec 不触发 zshexit,手动清
        # p10k instant prompt 与连环 exec 不兼容(第二次重载死在 zshrc 早期,
        # 黑匣子铁证);重载会话无需冷启动加速,用官方变量关掉它
        export POWERLEVEL9K_INSTANT_PROMPT=off
        exec zsh
      fi
      _yeterm_prompt_last="$t"
      # p10k 完整卸载/重装 + **选项主权接管**(2026-07-29 终极勘差,三条歧路
      # 全部实测排除:①trap 内手术=SIGSEGV;②只摘钩子的"挂起"=它的 zle 按键
      # 包装层仍活着,周期性越权改展开选项,agnoster 原始转义泄漏;③信任
      # teardown/setup 自身的选项快照=循环第二轮起快照代际污染,同样泄漏)。
      # 终解:手术只在安全点(zle -F/precmd)做,且每次手术后由**我们**把
      # prompt 展开选项强制钉死到已知正确值,不信任任何一方的恢复
      _yeterm_p10k_off() {
        (( $+functions[prompt_powerlevel9k_teardown] )) || return 0
        prompt_powerlevel9k_teardown 2>/dev/null
        setopt prompt_percent prompt_subst prompt_cr prompt_sp 2>/dev/null
        # teardown 会按 p10k 安装时的 zle 快照复原,把我们后注册的 -F 回调
        # 一并拆掉(黑匣子铁证:此后 handler 永不触发)—— 每次手术后补回(幂等)
        [[ -n "${_yeterm_fd-}" ]] && zle -F $_yeterm_fd _yeterm_zle_notify 2>/dev/null
      }
      _yeterm_p10k_on() {
        (( $+functions[prompt_powerlevel9k_setup] )) || return 0
        setopt prompt_percent prompt_cr prompt_sp 2>/dev/null   # 干净基线再装
        prompt_powerlevel9k_setup 2>/dev/null
        # ⚠️ 不手调 _p9k_precmd(zle -F 上下文执行会中途挂掉且注销 handler,
        # 黑匣子铁证):p10k 提示符由下一个 precmd/它自身机制现算
        [[ -n "${_yeterm_fd-}" ]] && zle -F $_yeterm_fd _yeterm_zle_notify 2>/dev/null
      }
      add-zsh-hook -d precmd _yeterm_dos_prompt 2>/dev/null   # 清上次复古挂载(幂等)
      case "$t" in
        omz:*)
          _yeterm_p10k_off
          RPROMPT=''
          (( $+functions[omz] )) && omz theme use "${t#omz:}" >/dev/null 2>&1
          ;;
        retro:*)
          # 内置复古提示符:卸载 p10k,纯字符串 PROMPT 接管
          _yeterm_p10k_off
          RPROMPT=''
          case "${t#retro:}" in
            ascii)   PROMPT='%n@%m:%~ %# ' ;;
            dos)
              # DOS 路径提示符:precmd 每次现算纯字符串(避开 PROMPT_SUBST 的
              # 多层转义地狱);路径 → 大写 + 反斜杠,~ 缩写 HOME,% 转义防注入
              _yeterm_dos_prompt() {
                local p=${PWD/#$HOME/\\~}
                p=${(U)p//\\//\\\\}
                PROMPT="C:${p//\\%/%%}> "
              }
              add-zsh-hook precmd _yeterm_dos_prompt
              _yeterm_dos_prompt
              ;;
            c64)     PROMPT=$'READY.\\n' ;;
            minimal) PROMPT='%# ' ;;
          esac
          ;;
        none)
          # 热切回"不干预":p10k 用户 = 干净基线重装;无 p10k 的 omz 用户 =
          # 重新加载 zshrc 原始主题(非 p10k 主题重复 source 安全)
          if [[ "$mode" == hot ]]; then
            if (( $+functions[prompt_powerlevel9k_setup] )); then
              _yeterm_p10k_on
            elif (( $+functions[omz] )) && [[ -n "$_yeterm_orig_theme" ]]; then
              omz theme use "$_yeterm_orig_theme" >/dev/null 2>&1
            fi
          fi
          ;;
      esac
    }
    # 启动路径不在此刻动手术(见 _yeterm_precmd 里的 boot 延迟说明):
    # 首个提示符短暂显示 p10k(instant prompt 画的缓存帧),首个 precmd 换装
    _yeterm_boot_pending=1
    # 热切换 v14 终极架构(2026-07-29 一日鏖战定稿):YeTerm 是终端模拟器,
    # 拥有 PTY 键盘注入权 —— 切主题时向本会话注入自定义按键序列 CSI 991~,
    # 下面把它绑定成 zle widget:**与用户手敲按键字面上同一条处理路径**
    # ("敲回车必生效"是全天真机验证 100% 成立的事实)。此前的
    # SIGUSR1/自管道 FIFO/zle -F 异步链全部退役(信号上下文 p10k 手术
    # SIGSEGV、zle -F 真机不唤醒、send-break/accept-line 在 -F 上下文失效
    # —— 三条异步路线的"隔离环境过、真机不过"教训俱在 git log)。
    _yeterm_apply_widget() {
      local t=""
      [[ -f "$_yeterm_prompt_file" ]] && t="$(<"$_yeterm_prompt_file")"
      if [[ "$t" == retro:* && "$_yeterm_prompt_last" == retro:* ]]; then
        _yeterm_apply_prompt hot        # 复古互切:纯变量,原地重画,不丢输入
        zle .reset-prompt
      else
        zle .kill-buffer 2>/dev/null    # 深水(涉 p10k/omz):清行+空回车 →
        zle .accept-line                #   precmd 在干净上下文 exec 会话重载
      fi
    }
    zle -N _yeterm_apply_widget 2>/dev/null
    bindkey '\\e[991~' _yeterm_apply_widget 2>/dev/null
    # 兼容:旧版 YeTerm 二进制仍可能发 SIGUSR1 —— 空接,防未捕获默认退出
    TRAPUSR1() { return 0 }
    # (握手 OSC 7777 由首个 precmd 发出,见 _yeterm_precmd —— 不在此处 printf,
    #  避免 p10k instant prompt 加载期输出警告)
    """

    /// zshrc 里的接线(单行,好认好删)
    static var sourceLine: String {
        "[[ -f \"$HOME/Library/Application Support/YeTerm/shell-integration.zsh\" ]] "
        + "&& source \"$HOME/Library/Application Support/YeTerm/shell-integration.zsh\"  \(marker)"
    }

    public static var isInstalled: Bool {
        guard let content = try? String(contentsOfFile: zshrcPath, encoding: .utf8) else { return false }
        return content.contains(marker)
    }

    // ---- 提示符主题状态文件(v1.3 热切换):YeTerm 写、集成脚本读 ----
    static let promptFilePath = NSHomeDirectory()
        + "/Library/Application Support/YeTerm/prompt-theme"

    /// 热切链路黑匣子(2026-07-29:用户真机复现 shell 退出而隔离环境全绿 ——
    /// YeTerm 侧与 shell 侧共写一份诊断日志,死亡现场留痕断案)
    static let debugLogPath = NSHomeDirectory()
        + "/Library/Application Support/YeTerm/prompt-debug.log"

    public static func debugLog(_ msg: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let line = "\(fmt.string(from: Date())) [app \(ProcessInfo.processInfo.processIdentifier)] \(msg)\n"
        if let h = FileHandle(forWritingAtPath: debugLogPath) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(toFile: debugLogPath, atomically: true, encoding: .utf8)
        }
    }

    /// 写当前提示符主题(nil = "none" 不干预);脚本启动与收到 SIGUSR1 时读它
    public static func writePromptTheme(_ theme: String?) {
        let dir = (promptFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (theme ?? "none").write(toFile: promptFilePath, atomically: true, encoding: .utf8)
    }

    /// 安装:①脚本落盘(总是覆盖=保持最新);②zshrc 追加 source(幂等)。
    /// 返回 nil = 成功;否则错误描述。
    public static func install() -> String? {
        let dir = (scriptPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            return Lf("集成脚本写入失败:%@", error.localizedDescription)
        }
        guard !isInstalled else { return nil }   // 已接线,只刷新了脚本
        let existing = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
            + "\n" + sourceLine + "\n"
        do {
            if FileManager.default.fileExists(atPath: zshrcPath) {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: zshrcPath))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(addition.utf8))
            } else {
                try (sourceLine + "\n").write(toFile: zshrcPath, atomically: true, encoding: .utf8)
            }
        } catch {
            return Lf("~/.zshrc 写入失败:%@", error.localizedDescription)
        }
        return nil
    }
}

/// oh-my-zsh 一键安装(v1.3 #1,用户需求:设置里点一下装好)。
/// 走官方 install.sh 的 **--unattended + 三环境变量**组合:RUNZSH=no(装完不自启
/// zsh)、CHSH=no(不改默认 shell)、KEEP_ZSHRC=yes(**绝不动用户 .zshrc**——
/// 官方默认行为会把 .zshrc 换成模板,p10k 配置和我们的集成行都会丢,红线)。
/// 装完由 ensureZshrcWired() 以幂等 marker 追加受控初始化块,且保证插在
/// YeTerm 集成行**之前**(集成脚本要在 omz 加载后才能 omz theme use)。
public enum OmzInstaller {
    static let omzDir = NSHomeDirectory() + "/.oh-my-zsh"
    static let zshrcPath = NSHomeDirectory() + "/.zshrc"
    /// ⚠️ **绝不能翻译**:这行会被写进用户的 ~/.zshrc,并用来判断"是否已接线"。
    ///    翻译了会出现:英文界面下接一次线、切回中文又判定没接过再接一次。
    ///    (i18n 批量包装时误包过一次,这里留个记号)
    static let wireMarker = "# YeTerm oh-my-zsh 接线"

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: omzDir + "/oh-my-zsh.sh")
    }

    /// 异步安装(网络下载,几秒~几十秒);完成回调在主线程,nil = 成功
    public static func install(completion: @escaping (String?) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "sh -c \"$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended"]
        var env = ProcessInfo.processInfo.environment
        env["RUNZSH"] = "no"
        env["CHSH"] = "no"
        env["KEEP_ZSHRC"] = "yes"
        p.environment = env
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        p.terminationHandler = { proc in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                if proc.terminationStatus == 0, isInstalled {
                    completion(ensureZshrcWired())
                } else {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    completion(Lf("安装脚本退出码 %d", proc.terminationStatus)
                               + (msg.isEmpty ? L("(请检查网络)") : ":\(msg.suffix(300))"))
                }
            }
        }
        do {
            try p.run()
        } catch {
            DispatchQueue.main.async { completion(Lf("无法启动安装进程:%@", error.localizedDescription)) }
        }
    }

    /// .zshrc 接线(幂等):已有任何 oh-my-zsh.sh 引用(用户自己配过)就不动;
    /// 否则把初始化块插在 YeTerm 集成行之前(没有集成行则追加末尾)
    static func ensureZshrcWired() -> String? {
        let existing = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        guard !existing.contains("oh-my-zsh.sh"), !existing.contains(wireMarker) else { return nil }
        let block = """
        \(wireMarker)
        export ZSH="$HOME/.oh-my-zsh"
        ZSH_THEME="robbyrussell"
        [[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

        """
        var content = existing
        if let range = content.range(of: ShellIntegration.sourceLine) {
            content.replaceSubrange(range, with: block + ShellIntegration.sourceLine)
        } else {
            content += (content.isEmpty || content.hasSuffix("\n") ? "" : "\n") + "\n" + block
        }
        do {
            try content.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return Lf("oh-my-zsh 已装好,但 ~/.zshrc 接线失败:%@", error.localizedDescription)
        }
    }
}

/// imgcat 一键安装(v1.2 #4 追加,用户需求:方便同事装)。
/// 脚本打包在 app 资源里(iTerm2 官方 utilities 版本,已实测配合多段协议出图),
/// 安装 = 拷到 ~/.local/bin + 确保 PATH 接线 —— 零网络依赖,离线可装。
public enum ImgcatInstaller {
    static let destPath = NSHomeDirectory() + "/.local/bin/imgcat"
    static let zshrcPath = NSHomeDirectory() + "/.zshrc"

    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: destPath)
    }

    /// 返回 nil = 成功;否则错误描述
    public static func install() -> String? {
        guard let src = Bundle.module.url(forResource: "imgcat", withExtension: nil,
                                          subdirectory: "Tools") else {
            return L("内置 imgcat 资源缺失(打包问题)")
        }
        let dir = (destPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destPath) {
                try FileManager.default.removeItem(atPath: destPath)
            }
            try FileManager.default.copyItem(at: src, to: URL(fileURLWithPath: destPath))
            // 【学】.copy 资源会丢执行位,装完补 chmod 755
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: destPath)
        } catch {
            return Lf("imgcat 安装失败:%@", error.localizedDescription)
        }
        // PATH 接线:zshrc 里没有 ~/.local/bin 就追加一行(宽松探测,已有任何写法都算)
        let existing = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        if !existing.contains(".local/bin") {
            let line = "export PATH=\"$HOME/.local/bin:$PATH\"  # YeTerm imgcat\n"
            let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + line
            do {
                if FileManager.default.fileExists(atPath: zshrcPath) {
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: zshrcPath))
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(addition.utf8))
                } else {
                    try line.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
                }
            } catch {
                return Lf("imgcat 已装好,但 ~/.zshrc PATH 接线失败:%@", error.localizedDescription)
            }
        }
        return nil
    }
}
