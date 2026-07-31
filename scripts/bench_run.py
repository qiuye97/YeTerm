#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# 📖 初学者导读 —— 终端吞吐横向跑分器
#
# 这个文件干嘛的:测「终端把字符画上屏有多快」,并且能跨终端横着比。
#
# 为什么必须是外部脚本,不能做成 YeTerm 的 --bench:
#   要横向对比,就得在 Terminal.app / cool-retro-term 里也跑同一份数据,
#   而它们没有我们的命令行参数。所以跑分器必须是「终端无关」的 ——
#   任何终端里敲一行命令就能跑。这也是 alacritty/vtebench 的做法。
#
# 测量原理(关键,别改坏):
#   我们把一大坨字节 write() 到 stdout。stdout 那头是 PTY,
#   **PTY 的缓冲区是有限的** —— 终端读得慢,缓冲区就满,我们的 write() 就阻塞。
#   所以「write 全部写完花了多久」≈「终端消化这些字节花了多久」。
#   类比:往一根水管灌水,水管另一头出水慢,你就灌得慢 —— 灌完的耗时反映出水速度。
#
#   计时必须包住 write+flush,且**不能**用 `time cat file` 那种外部计时:
#   进程启动开销(几十毫秒)会污染结果,量级和我们要测的差不多。
#
# 结果落盘到 .bench/results/<标签>.tsv,每个终端跑一次,最后 --report 合并成表。
# ─────────────────────────────────────────────────────────────────────────────
import argparse
import json
import os
import platform
import random
import select
import shutil
import subprocess
import sys
import termios
import time
import tty

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH_DIR = os.path.join(ROOT, ".bench")
PAYLOAD_DIR = os.path.join(BENCH_DIR, "payloads")
RESULT_DIR = os.path.join(BENCH_DIR, "results")

# 负载规模系数。所有终端**必须用同一个** scale,否则数字不可比 ——
# 结果文件里会记下它,--report 时发现不一致会拒绝合并。
SCALE = float(os.environ.get("BENCH_SCALE", "1.0"))
REPEAT = int(os.environ.get("BENCH_REPEAT", "3"))

# 测量方法版本。改了计时口径就 +1 —— 老结果和新结果混在一张表里比是自欺,
# --report 发现版本不一致会报警。
# v1 = 只测 write 写完;v2 = 追加 DSR 往返同步(见 sync_roundtrip)
METHOD = 2

# 统一窗口格数。**「都全屏最大化」不等于同尺寸** —— 各终端默认字号不同,
# 同一块屏幕分出来的格子数能差近一倍(实测 181x43 到 212x71)。
# 所以由脚本用 CSI 8;行;列 t 主动把窗口钉到同一格数,钉不动就拒绝跑。
TARGET_COLS = int(os.environ.get("BENCH_COLS", "100"))
TARGET_ROWS = int(os.environ.get("BENCH_ROWS", "30"))

# ── 负载生成 ──────────────────────────────────────────────────────────────
# 每个负载压一种不同的解析路径,别只测纯文本(那只反映最顺的那条路)。

def gen_scroll_plain(mb):
    """纯 ASCII 滚动 —— 最基础的吞吐,只走「写字符 + 滚屏」"""
    line = ("".join(chr(33 + (i % 94)) for i in range(79)) + "\n").encode()
    return line * int(mb * 1024 * 1024 / len(line))


def gen_scroll_color(mb):
    """密集 SGR 变色 —— 每几个字符就切前景色,压属性解析与属性合批"""
    out = bytearray()
    target = int(mb * 1024 * 1024)
    rnd = random.Random(42)          # 固定种子 = 每次生成的负载逐字节一致
    while len(out) < target:
        row = bytearray()
        for _ in range(16):
            row += b"\x1b[38;5;%dm" % rnd.randint(16, 231)
            row += b"ABCDE"
        row += b"\x1b[0m\n"
        out += row
    return bytes(out)


def gen_scroll_cjk(mb):
    """中日韩宽字符 —— 压宽字符宽度计算与「一个字占两格」的网格摆放。
    这是 YeTerm 的立项理由所在(cool-retro-term 在特效模式下根本显示不了中文)"""
    zh = "复古终端渲染管线字形图集扫描线余辉磷光荧光屏幕弧度噪点色差机壳反射"
    line = ("".join(zh[i % len(zh)] for i in range(39)) + "\n").encode("utf-8")
    return line * int(mb * 1024 * 1024 / len(line))


def gen_screen_redraw(times):
    """整屏重绘 —— vim/tmux/htop 的典型行为:光标归位 + 重画满屏。
    压的是「大量光标定位 + 覆盖写」,不是滚屏"""
    out = bytearray()
    for n in range(times):
        out += b"\x1b[H"                       # 光标归位
        for row in range(24):
            out += b"\x1b[%d;1H" % (row + 1)   # 定位到行首
            out += b"%-79s" % (b"redraw frame %d row %d" % (n, row))
    return bytes(out)


def gen_cursor_jump(times):
    """光标随机跳转 —— 每次只写一个字符,把开销全压在 CUP 转义序列解析上。
    很多终端在这条路上会露馅(每个转义序列都要走一遍状态机)"""
    out = bytearray()
    rnd = random.Random(7)
    for _ in range(times):
        out += b"\x1b[%d;%dH" % (rnd.randint(1, 24), rnd.randint(1, 80))
        out += bytes([rnd.randint(65, 90)])
    return bytes(out)


# 场景表:(键, 中文名, 生成函数, 规模参数, 规模单位说明)
SCENARIOS = [
    ("scroll_plain",  "纯文本滚动",    gen_scroll_plain,  6.0,    "MB"),
    ("scroll_color",  "密集 ANSI 颜色", gen_scroll_color,  6.0,    "MB"),
    ("scroll_cjk",    "中文宽字符",    gen_scroll_cjk,    6.0,    "MB"),
    ("screen_redraw", "整屏重绘",      gen_screen_redraw, 2500,   "次"),
    ("cursor_jump",   "光标随机跳转",  gen_cursor_jump,   150000, "次"),
]


def payload_path(key):
    return os.path.join(PAYLOAD_DIR, f"{key}_s{SCALE:g}.bin")


def ensure_payloads(verbose=True):
    os.makedirs(PAYLOAD_DIR, exist_ok=True)
    for key, name, fn, size, unit in SCENARIOS:
        p = payload_path(key)
        if os.path.exists(p):
            continue
        if verbose:
            print(f"  生成负载 {name} ...", file=sys.stderr)
        scaled = size * SCALE if unit == "MB" else int(size * SCALE)
        with open(p, "wb") as f:
            f.write(fn(scaled))


# ── 运行环境采集(公平性证据:条件不同的结果不能放一起比)────────────────────

def term_size():
    try:
        s = os.get_terminal_size()
        return s.columns, s.lines
    except OSError:
        return 0, 0


def detect_label():
    """尽力自动识别当前终端。YeTerm 现在会设 TERM_PROGRAM(2026-07-30 补的)"""
    tp = os.environ.get("TERM_PROGRAM", "")
    mapping = {
        "YeTerm": "YeTerm",
        "Apple_Terminal": "Terminal.app",
        "iTerm.app": "iTerm2",
        "ghostty": "Ghostty",
        "WezTerm": "WezTerm",
    }
    if tp in mapping:
        return mapping[tp]
    if tp:
        return tp
    # cool-retro-term 不设 TERM_PROGRAM,靠祖先进程名兜底
    try:
        ppid = os.getppid()
        for _ in range(6):
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(ppid)],
                                 capture_output=True, text=True, timeout=2).stdout.strip()
            if not out:
                break
            parts = out.split(None, 1)
            if len(parts) < 2:
                break
            nxt, comm = parts
            base = os.path.basename(comm).lower()
            for k in ("cool-retro-term", "iterm", "ghostty", "kitty", "alacritty",
                      "wezterm", "warp", "hyper", "tabby", "xterminal", "yeterm"):
                if k in base:
                    return os.path.basename(comm)
            ppid = int(nxt)
    except Exception:
        pass
    return "unknown"


# ── 测量 ─────────────────────────────────────────────────────────────────

def reset_screen():
    """两次跑之间清干净:属性复位 + 清屏 + 光标归位。
    不用 RIS(\\x1bc) —— 那会连滚动区/字符集一起重置,某些终端还会闪窗口"""
    sys.stdout.buffer.write(b"\x1b[0m\x1b[2J\x1b[H")
    sys.stdout.buffer.flush()


def tty_query(seq, timeout=1.5):
    """向终端发一段查询序列,读回它的回复(裸字节)。读不到返回 None。
    原理和 sync_roundtrip 一样:把 stdin 切到 raw 模式,自己收回复
    (平时这些回复会被 shell 当成用户输入)。"""
    if not sys.stdin.isatty():
        return None
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        termios.tcflush(fd, termios.TCIFLUSH)
        sys.stdout.buffer.write(seq)
        sys.stdout.buffer.flush()
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                buf += os.read(fd, 64)
                if buf.endswith(b"t") or buf.endswith(b"R"):
                    return buf
        return buf or None
    except termios.error:
        return None
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def pixel_metrics():
    """问终端要「文本区像素尺寸」和「单元格像素尺寸」。

    为什么要这个:脚本钉的是**格子数**(100x30),但各终端字号不同 →
    同样 100x30 格,像素面积能差两三倍。像素面积决定 GPU 分片着色量,
    对 YeTerm 这种带全屏后处理的尤其相关。
    与其要求用户手动统一字号(还容易忘/记错),不如把它测出来记进结果 ——
    **能测的变量就别靠纪律维持**。

    CSI 14 t → 回 CSI 4;高;宽 t(文本区像素)
    CSI 16 t → 回 CSI 6;高;宽 t(单元格像素)
    不是所有终端都支持,拿不到就记 None。"""
    def parse(reply, want):
        if not reply:
            return None
        try:
            body = reply.split(b"\x1b[", 1)[1].rstrip(b"t")
            parts = body.split(b";")
            if len(parts) == 3 and int(parts[0]) == want:
                return (int(parts[2]), int(parts[1]))   # (宽, 高)
        except (ValueError, IndexError):
            pass
        return None

    area = parse(tty_query(b"\x1b[14t"), 4)
    cell = parse(tty_query(b"\x1b[16t"), 6)
    return area, cell


def force_size(cols, rows):
    """用 CSI 8;行;列 t 把终端窗口钉到指定格数,返回是否钉成功。
    这是 xterm 的窗口操作序列,主流终端都认。全屏状态下多半会被忽略 ——
    所以钉不动时我们直接拒绝跑,而不是拿着不可比的数字往下走。"""
    sys.stdout.buffer.write(b"\x1b[8;%d;%dt" % (rows, cols))
    sys.stdout.buffer.flush()
    for _ in range(12):                 # 等窗口真的改完(SIGWINCH 是异步的)
        time.sleep(0.1)
        if term_size() == (cols, rows):
            return True
    return False


# 终端是否支持 DSR 光标查询。启动时探一次 —— 不支持的话每次都等 60 秒超时,
# 5 场景×3 次要白等十几分钟。探到不支持就整轮跳过同步,并在结果里标记。
DSR_OK = True


def probe_dsr():
    """开跑前用短超时探一次终端认不认 `ESC[6n`"""
    global DSR_OK
    DSR_OK = sync_roundtrip(timeout=2.0, _probe=True)
    return DSR_OK


def sync_roundtrip(timeout=60.0, _probe=False):
    """**收尾往返同步** —— 这是 v1 方法的漏洞所在,必须有。

    只测「write 写完」是不够的:有些终端会贪婪地把 PTY 里的字节先吸进自己的
    缓冲区、之后慢慢处理。那样 write 早就返回了,终端其实还在追赶,
    测出来的是「吞下去多快」而不是「消化完多快」。

    做法:写完负载后发一个光标位置查询(DSR,`ESC[6n`),等终端回话。
    终端是**顺序处理**输入的 —— 它能回答这个问题,就证明前面的字节全处理完了。
    类比:排队办事,你在队尾喊一嗓子问"到我了吗",听到回答就说明前面都办完了。

    返回 True=同步成功;False=终端没回话(超时),该结果的可信度要打折。"""
    if not sys.stdin.isatty():
        return False
    if not DSR_OK and not _probe:       # 已探明不支持,别再每次白等超时
        return False
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        termios.tcflush(fd, termios.TCIFLUSH)   # 丢掉之前的杂散输入,免得误读成回复
        sys.stdout.buffer.write(b"\x1b[6n")
        sys.stdout.buffer.flush()
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                buf += os.read(fd, 64)
                if b"R" in buf:             # 回复形如 ESC[行;列R
                    return True
        return False
    except termios.error:
        return False
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def measure(data):
    """核心:计时包住 write+flush **+ 往返同步**。返回 (秒数, 是否同步成功)。
    stdout 被 PTY 反压时 write 会阻塞,阻塞时长反映终端的消化速度;
    末尾的同步保证「消化完」而不只是「吞下去」。"""
    out = sys.stdout.buffer
    t0 = time.perf_counter()
    out.write(data)
    out.flush()
    synced = sync_roundtrip()
    t1 = time.perf_counter()
    return t1 - t0, synced


def run_bench(label, note):
    cols, rows = term_size()
    if cols == 0:
        print("✗ 拿不到终端尺寸 —— 必须在真实终端窗口里跑,不能重定向到文件/管道",
              file=sys.stderr)
        return 1

    # 统一窗口格数 —— 不统一就没有可比性,所以这里钉不动直接拒跑
    if (cols, rows) != (TARGET_COLS, TARGET_ROWS):
        print(f"把窗口钉到 {TARGET_COLS}x{TARGET_ROWS}(当前 {cols}x{rows})...",
              file=sys.stderr)
        if not force_size(TARGET_COLS, TARGET_ROWS):
            cols, rows = term_size()
            print(f"\n✗ 窗口没能改成 {TARGET_COLS}x{TARGET_ROWS},现在是 {cols}x{rows}",
                  file=sys.stderr)
            print("  常见原因:窗口处于**全屏状态**(全屏时终端会忽略改尺寸请求)。",
                  file=sys.stderr)
            print("  请退出全屏(⌃⌘F 或绿灯)后重跑。", file=sys.stderr)
            print("  「都最大化」并不等于同尺寸 —— 各终端字号不同,格子数能差近一倍,",
                  file=sys.stderr)
            print("  而列×行直接决定工作量,不统一的数字放一起比没有意义。",
                  file=sys.stderr)
            return 1
        cols, rows = term_size()
    ensure_payloads()
    area_px, cell_px = pixel_metrics()
    if cell_px:
        print(f"  单元格 {cell_px[0]}x{cell_px[1]} px"
              + (f",文本区 {area_px[0]}x{area_px[1]} px" if area_px else ""),
              file=sys.stderr)

    if not probe_dsr():
        print("\n⚠️ 该终端不响应光标位置查询(ESC[6n),本轮跳过收尾同步。",
              file=sys.stderr)
        print("   后果:只能测到「字节被吞下去多快」,测不到「是否真的处理完」,",
              file=sys.stderr)
        print("   如果这个终端在后台偷偷追赶,数字会偏乐观。结果里已标记。",
              file=sys.stderr)

    print(f"\n跑分开始:{label}", file=sys.stderr)
    print(f"  窗口 {cols}x{rows}  scale={SCALE:g}  每场景跑 {REPEAT} 次取中位数",
          file=sys.stderr)
    print(f"  ⚠️ 测量期间请勿切走窗口 —— 终端被遮挡时会跳过渲染,数字会虚低\n",
          file=sys.stderr)
    time.sleep(1.0)

    results = {}
    unsynced = []
    for key, name, _fn, size, unit in SCENARIOS:
        with open(payload_path(key), "rb") as f:
            data = f.read()
        times, syncs = [], []
        for _ in range(REPEAT):
            reset_screen()
            time.sleep(0.15)          # 让终端把上一轮排空,别把余波算进下一轮
            t, ok = measure(data)
            times.append(t)
            syncs.append(ok)
        reset_screen()
        times.sort()
        med = times[len(times) // 2]
        synced = all(syncs)
        if not synced:
            unsynced.append(name)
        results[key] = {"median": med, "all": times, "bytes": len(data),
                        "synced": synced}
        mbps = len(data) / 1024 / 1024 / med if med > 0 else 0
        flag = "" if synced else "  ⚠️未同步"
        print(f"  {pad(name, 16)}{med:7.3f}s   ({mbps:6.1f} MB/s){flag}",
              file=sys.stderr)

    if unsynced:
        print(f"\n⚠️ 这些场景终端没回应光标查询:{', '.join(unsynced)}", file=sys.stderr)
        print("   说明该终端可能没真正处理完就返回了,这几个数字要打折看。",
              file=sys.stderr)

    os.makedirs(RESULT_DIR, exist_ok=True)
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in label)
    path = os.path.join(RESULT_DIR, f"{safe}.json")
    with open(path, "w") as f:
        json.dump({
            "label": label,
            "note": note,
            "scale": SCALE,
            "method": METHOD,
            "repeat": REPEAT,
            "cols": cols, "rows": rows,
            "cell_px": cell_px, "area_px": area_px,
            "term": os.environ.get("TERM", ""),
            "term_program": os.environ.get("TERM_PROGRAM", ""),
            "machine": platform.machine(),
            "results": results,
        }, f, ensure_ascii=False, indent=1)
    print(f"\n✓ 已存 {os.path.relpath(path, ROOT)}", file=sys.stderr)
    print("  换个终端再跑一次,全部跑完后执行:bash scripts/bench.sh --report",
          file=sys.stderr)
    return 0


# ── 报表 ─────────────────────────────────────────────────────────────────

def dwidth(s):
    """字符串的**显示宽度**(格数),中日韩宽字符算 2 格。
    Python 的 ljust/rjust 按「字符个数」补,中文表格必歪 —— 必须自己算。
    判据用 East Asian Width 的 W/F 两类,和终端的宽度表同源。"""
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)


def pad(s, width, right=False):
    """按显示宽度补空格"""
    gap = max(width - dwidth(s), 0)
    return (" " * gap + s) if right else (s + " " * gap)


def load_results():
    if not os.path.isdir(RESULT_DIR):
        return []
    out = []
    for fn in sorted(os.listdir(RESULT_DIR)):
        if fn.endswith(".json"):
            with open(os.path.join(RESULT_DIR, fn)) as f:
                out.append(json.load(f))
    return out


def report():
    runs = load_results()
    if not runs:
        print("还没有任何结果。先在各个终端里跑 bash scripts/bench.sh", file=sys.stderr)
        return 1

    # 公平性校验:scale 与窗口尺寸不一致的结果放一起比是没意义的
    scales = {r["scale"] for r in runs}
    sizes = {(r["cols"], r["rows"]) for r in runs}
    methods = {r.get("method", 1) for r in runs}
    warn = []
    if len(scales) > 1:
        warn.append(f"负载规模不一致 scale={sorted(scales)} —— 这些数字**不可比**,请统一后重跑")
    if len(sizes) > 1:
        warn.append(f"窗口尺寸不一致 {sorted(sizes)} —— 列×行直接决定工作量,必须统一后重跑")
    if len(methods) > 1:
        warn.append(f"测量方法版本不一致 method={sorted(methods)} —— v1 只测「写完」、"
                    "v2 追加了往返同步(测「消化完」),两者口径不同**不可比**,请全部重跑")
    nosync = [r["label"] for r in runs
              if any(not v.get("synced", True) for v in r["results"].values())]
    if nosync:
        warn.append(f"这些终端未响应光标查询(可能没处理完就返回):{', '.join(nosync)} —— 其数字偏乐观")

    labels = [r["label"] for r in runs]
    namew = max(dwidth(s[1]) for s in SCENARIOS) + 2
    colw = max(max((dwidth(l) for l in labels), default=8), 11) + 2
    total_w = namew + colw * len(runs)

    print()
    print("终端吞吐横向对比(每格 = 耗时秒数,越小越快)")
    print("=" * total_w)
    print(pad("场景", namew) + "".join(pad(l, colw, right=True) for l in labels))
    print("-" * total_w)

    def line(name, vals, fmt):
        best = min([v for v in vals if v is not None], default=None)
        row = pad(name, namew)
        for v in vals:
            if v is None:
                cell = "—"
            else:
                # 最快的那个打星,一眼看出每个场景谁赢
                cell = fmt(v) + ("*" if best and abs(v - best) < 1e-9 else " ")
            row += pad(cell, colw, right=True)
        print(row)

    for key, name, _fn, _s, _u in SCENARIOS:
        vals = [(r["results"].get(key) or {}).get("median") for r in runs]
        line(name, vals, lambda v: f"{v:.3f}s")

    print("-" * total_w)
    totals = [sum(v["median"] for v in r["results"].values()) for r in runs]
    line("合计", totals, lambda v: f"{v:.3f}s")
    # 相对倍数:以最快者为 1.00x —— 比绝对秒数更容易记住差距
    fastest = min(totals) if totals else 1
    line("相对", [t / fastest for t in totals], lambda v: f"{v:.2f}x")
    print("=" * total_w)
    print("* = 该场景最快;「相对」以最快者为 1.00x")

    print("\n运行条件:")
    for r in runs:
        cell = r.get("cell_px")
        px = f"  单元格 {cell[0]}x{cell[1]}px" if cell else "  单元格 ?(终端不报)"
        area = r.get("area_px")
        if area:
            px += f" → 文本区 {area[0]}x{area[1]}px"
        print(f"  {pad(r['label'], 20)}{r['cols']}x{r['rows']} 格{px}  "
              f"TERM={r['term']} {r.get('note') or ''}")

    # 格子数已由脚本钉死统一,但字号不同 → 像素面积仍可能差几倍。
    # 像素面积决定 GPU 分片着色量,差太多时提醒一句(不阻断:实测渲染不是吞吐瓶颈)
    areas = [(r["label"], r["area_px"][0] * r["area_px"][1])
             for r in runs if r.get("area_px")]
    if len(areas) >= 2:
        lo = min(a for _, a in areas)
        hi = max(a for _, a in areas)
        if hi > lo * 1.5:
            big = max(areas, key=lambda x: x[1])
            small = min(areas, key=lambda x: x[1])
            warn.append(
                f"像素面积差 {hi/lo:.1f} 倍({small[0]} 最小、{big[0]} 最大)—— "
                "格子数已统一,这是**字号**不同造成的。它只影响 GPU 分片着色量,"
                "不影响 VT 解析;实测特效开关对吞吐无影响(说明渲染不是瓶颈),"
                "故一般可忽略。若要彻底消除该变量,把各终端字号调成一致后重跑。")

    for wmsg in warn:
        print(f"\n⚠️ {wmsg}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="终端吞吐横向跑分")
    ap.add_argument("--label", help="本次运行的名字,如 'YeTerm CRT-on'")
    ap.add_argument("--note", default="", help="备注,写进结果文件")
    ap.add_argument("--report", action="store_true", help="合并所有结果打印对比表")
    ap.add_argument("--clean", action="store_true", help="清空已有结果")
    ap.add_argument("--list", action="store_true", help="列出已有结果")
    args = ap.parse_args()

    if args.clean:
        shutil.rmtree(RESULT_DIR, ignore_errors=True)
        print("已清空结果", file=sys.stderr)
        return 0
    if args.list:
        for r in load_results():
            print(f"  {r['label']:<24} 窗口 {r['cols']}x{r['rows']}  scale={r['scale']:g}")
        return 0
    if args.report:
        return report()

    label = args.label or detect_label()
    if label == "YeTerm" and not args.label:
        print("检测到 YeTerm。CRT 特效必须分开记录 —— 请指明当前状态:", file=sys.stderr)
        print("  1) CRT 特效开   2) CRT 特效关", file=sys.stderr)
        try:
            c = input("选择 [1/2]: ").strip()
        except (EOFError, KeyboardInterrupt):
            return 1
        label = "YeTerm CRT-on" if c == "1" else "YeTerm CRT-off"
    return run_bench(label, args.note)


if __name__ == "__main__":
    sys.exit(main())
