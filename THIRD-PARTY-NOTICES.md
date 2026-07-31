# 第三方组件与许可 / Third-Party Notices

YeTerm 本体以 **GPL-3.0-or-later** 分发（见根目录 `LICENSE`）。
本文件列出随 YeTerm 一同分发或被其依赖的第三方素材及其各自许可。

> 为什么是 GPL-3：`Sources/YeTermKit/Resources/Shaders/` 下的 CRT 特效着色器
> 是从 cool-retro-term 的 GLSL **逐行移植**而来的派生作品，其许可为
> GPL-3.0-or-later，具有传染性。

---

## 一、代码与素材

### cool-retro-term — GPL-3.0-or-later

- 来源：<https://github.com/Swordfish90/cool-retro-term>
- 版权：Copyright (C) Filippo Scognamiglio 等
- 用途：
  - `Sources/YeTermKit/Resources/Shaders/CRT.metal`、`BurnIn.metal`、`Bloom.metal`
    的 CRT 特效数学由其 `.frag` 着色器移植而来（GLSL → Metal MSL）。
  - `Sources/YeTermKit/Resources/Textures/allNoise512.png` —— 噪点纹理，原样取自
    其 `app/shaders/`（雪花/闪烁/抖动全靠查这张图，不是程序生成）。
  - 内置预设的参数默认值参照其 `AppSettings.qml` 还原。
  - 终端 16 色调色板取自 qmltermwidget 的 `cool-retro-term.colorscheme`。

### SwiftTerm — MIT

- 来源：<https://github.com/migueldeicaza/SwiftTerm>
- 版权：Copyright (c) Miguel de Icaza
- 用途：终端仿真内核（PTY、VT100/xterm 解析、字符网格、选区、IME 宿主）。
- 说明：YeTerm 依赖的是一个 **fork**（<https://github.com/qiuye97/SwiftTerm>，
  分支 `yeterm-perf`），在上游 v1.15.0 基础上打了两个补丁：CJK 解析快路径、
  以及把写死 60fps 的内容更新合并间隔改为可由宿主设置。补丁同为 MIT。

### imgcat（`Sources/YeTermKit/Resources/Tools/imgcat`）— 本项目原创

由 YeTerm 自行编写，随本项目以 GPL-3.0-or-later 分发。
它实现的 iTerm2 Inline Images 协议本身是公开规范，不受版权保护。

---

## 二、内置字体

所有内置字体均**未经修改**随包分发，各自许可全文见
`Sources/YeTermKit/Resources/Fonts/LICENSES/`（该目录会一并打进 .app）。

| 字体文件 | 字体名 | 作者 / 版权 | 许可 | 随包分发条件 |
|---|---|---|---|---|
| `ArkPixel12pxMono-zh_cn.ttf` | Ark Pixel 12px Mono zh_cn（方舟像素） | TakWolf | **SIL OFL 1.1** | 附 OFL 全文；保留字体名 |
| `TerminusTTF-4.46.0.ttf` | Terminus (TTF) | Dimitar Toshkov Zhekov / Tilman Blumenbach | **SIL OFL 1.1** | 附 OFL 全文 |
| `Inconsolata.otf` | Inconsolata | Raph Levien | **SIL OFL 1.1** | 附 OFL 全文 |
| `Hermit-medium.otf` | Hermit | Pablo Caro | **SIL OFL 1.1** | 附 OFL 全文；保留字体名 |
| `FSEX301-L2.ttf` | Fixedsys Excelsior 3.01-L2 | Darien Valentine | **公有领域 / CC0** | 无 |
| `ProggyTiny.ttf` | ProggyTinyTT | Tristan Grimmer | **MIT** | 附 MIT 全文与版权声明 |
| `ProFontWindows.ttf` | ProFontWindows | ProFont 项目（Mike Smith 转 Windows TTF） | **Freeware** | 附上游 `license.txt`（"free to use for both personal and commercial applications"） |
| `PxPlus_IBM_VGA8.ttf` | PxPlus IBM VGA8 | VileR (int10h.org) | **CC BY-SA 4.0** | 署名 VileR；相同方式共享 |
| `PxPlus_IBM_BIOS.ttf` | PxPlus IBM BIOS | VileR (int10h.org) | **CC BY-SA 4.0** | 同上 |
| `PetMe.ttf` | Pet Me | Rebecca Bettencourt / Kreative Software | **Kreative Software Relay Fonts Free Use License 1.2f** | 不得售卖；附许可全文；署名 Kreative；不得修改 |
| `PrintChar21.ttf` | Print Char 21 | Rebecca Bettencourt / Kreative Software | 同上 | 同上 |
| `AtariClassic-Regular.ttf` | Atari Classic | Mark Simonson | **Copyrighted freeware** | 不得修改；**必须随附其 Read Me**（已放入 LICENSES/）；不得随收费软件分发 |
| `C64_Pro_Mono-STYLE.ttf` | C64 Pro Mono | Style (style64.org) | **Style64 自定义许可** | 不得售卖；不得改名/改文件名；**仅可随免费提供给终端用户的软件包分发** |

### 关于 C64 Pro Mono 的说明

其许可明确允许「as part of a software package but ONLY if said software package
is freely provided to end users」，YeTerm 免费提供、文件未改名未修改，符合该条。
同时该许可禁止「provide the font for direct download from any web site」——
本仓库中该 .ttf 是作为软件源码的一部分存在，不是作为字体下载服务提供。
若 Style 认为此种形式不妥，请与我们联系，我们会立即移除并改为引导用户
从 <http://style64.org/c64-truetype> 自行下载安装。

### 关于 Zpix「最像素」的说明（留档）

本项目早期曾内置 Zpix 的 Mono 转换版作为中文点阵字体。开源前复核发现
Zpix（<https://github.com/SolidZORO/zpix-pixel-font>）为**商业授权字体**：
个人使用免费，但明确禁止修改、转换、传播。我们内置的正是转换产物，
无法随开源项目分发，**已于开源前移除**，改用同为点阵风格、授权为
SIL OFL 1.1 的 **Ark Pixel（方舟像素）**。

用户若已自行安装 Zpix，YeTerm 的字体库仍会正常列出并可选用 —— 那属于用户与
字体作者之间的授权关系，与本项目的分发无关。

---

## 三、致谢

- **cool-retro-term** —— 本项目的观感标杆与技术底稿。没有它就没有 YeTerm。
  YeTerm 的目标不是取代它，而是在保留那份味道的前提下修掉三处硬伤
  （arm64 原生、任意字体 × 中文 × 全特效、多窗口）。
- **Cathode**（Secret Geometry 出品）—— 一款做得非常漂亮的商业复古终端。
  它对「文字发光」的处理给了我们重要启发：**笔画自身发白**和**照亮周围**
  其实是两件互不相干的事，应该分开调。YeTerm 的 `overdrive`（白热化）
  正是循着这个思路自行设计实现的。向它的作者致敬。
- **SwiftTerm** —— 省掉了整个终端仿真内核，本项目才得以只专注在渲染与界面上。
