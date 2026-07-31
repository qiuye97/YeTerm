#!/bin/bash
# 提示符主题集成脚本回归(v1.3):从 Swift 源提取生成的 zsh 脚本 → 语法检查 →
# expect 真实伪终端压力测试(六连切/切回 p10k/无信号 precmd 保底)。
# 依赖本机 oh-my-zsh + powerlevel10k(开发机自测工具;同事机可跳过)。
# 末行 PROMPT-GREEN 为过。
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK" <<'EOF'
import re, sys
src = open('Sources/YeTermKit/Config/ShellIntegration.swift').read()
m = re.search(r'static let script = """\n(.*?)\n    """', src, re.S)
lines = [l[4:] if l.startswith('    ') else l for l in m.group(1).split('\n')]
s = '\n'.join(lines).replace('\\(marker)', '# marker')
s = s.replace('\\\\', '\x00').replace('\x00', '\\')
open(sys.argv[1] + '/integ.zsh', 'w').write(s)
EOF
zsh -n "$WORK/integ.zsh"
echo "语法 OK"

if [[ ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
  echo "本机无 oh-my-zsh,跳过压力测试"; echo "PROMPT-GREEN"; exit 0
fi
mkdir -p "$WORK/home/Library/Application Support/YeTerm" "$WORK/zdot"
cat > "$WORK/zdot/.zshrc" <<ZRC
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
[[ -f "\$ZSH/oh-my-zsh.sh" ]] && source "\$ZSH/oh-my-zsh.sh"
[[ -f "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"
source "$WORK/integ.zsh"
ZRC
echo "none" > "$WORK/home/Library/Application Support/YeTerm/prompt-theme"

cat > "$WORK/stress.exp" <<'EXPECT'
set timeout 20
proc setTheme {t} {
    exec sh -c "echo $t > '$::env(FAKEHOME)/Library/Application Support/YeTerm/prompt-theme'"
}
spawn env HOME=$env(FAKEHOME) TERM_PROGRAM=YeTerm ZDOTDIR=$env(ZDOT) TERM=xterm-256color zsh -i
set zshpid [exp_pid]
expect { "❯" {} timeout { puts "\nFAIL: 启动"; exit 1 } }
foreach t {omz:agnoster omz:ys omz:bira omz:gentoo retro:dos omz:af-magic} {
    setTheme $t
    send -- "\x1b\[991~"
    after 400
    if {[catch {exec kill -0 $zshpid}]} { puts "\nFAIL: shell 在切 $t 后死亡"; exit 1 }
}
setTheme retro:c64
send -- "\x1b\[991~"
expect { "READY." {} eof { puts "\nFAIL: c64 后死亡"; exit 1 } timeout { puts "\nFAIL: c64 未生效"; exit 1 } }
setTheme none
send -- "\x1b\[991~"
expect { "❯" {} eof { puts "\nFAIL: 回 p10k 死亡"; exit 1 } timeout { puts "\nFAIL: p10k 未恢复"; exit 1 } }
setTheme retro:dos
after 300
send "\r"
expect { -re {C:\\[A-Z]} {} timeout { puts "\nFAIL: 无信号保底未同步"; exit 1 } }
setTheme none
send "\r"
expect { "❯" {} timeout { puts "\nFAIL: 保底回 p10k 失败"; exit 1 } }
send "exit\r"
expect eof
# —— 用户链复刻(2026-07-29):启动时状态文件已是复古(如 Default Amber 预设
#    下重启),instant prompt 未走完即被 teardown → 切回 none 必须能恢复 p10k
exec sh -c "echo retro:ascii > '$::env(FAKEHOME)/Library/Application Support/YeTerm/prompt-theme'"
spawn env HOME=$env(FAKEHOME) TERM_PROGRAM=YeTerm ZDOTDIR=$env(ZDOT) TERM=xterm-256color zsh -i
set zshpid [exp_pid]
expect { -re {@[^\r\n]*%} {} timeout { puts "\nFAIL: 复古启动"; exit 1 } }
setTheme none
send -- "\x1b\[991~"
expect { "❯" {} eof { puts "\nFAIL: 复古启动→回 p10k shell 死亡"; exit 1 } timeout { puts "\nFAIL: 复古启动→p10k 未恢复"; exit 1 } }
send "exit\r"
expect eof
EXPECT
FAKEHOME="$WORK/home" ZDOT="$WORK/zdot" expect "$WORK/stress.exp" >/dev/null 2>&1 \
  || { echo "压力测试失败(expect 详情:手动跑 expect 去掉重定向)"; exit 1; }
echo "六连切/回 p10k/无信号保底 全过"
echo "PROMPT-GREEN"
