// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 整个程序的入口(从这里开始读整个项目!)
//
// 这个文件:YeTerm 可执行程序的入口,只有一行真正的代码。
// 类比 Java:相当于 `public static void main(String[] args)`,
//   但 Swift 的可执行目标里,名为 main.swift 的文件本身就是 main 函数——
//   写在文件顶层的代码会按顺序直接执行,不需要包一层函数。
//
// 项目结构(对照 Package.swift 理解,类比 Maven 的 pom.xml):
//   Sources/YeTerm/     → 薄壳可执行(就这一个文件),类比 Spring Boot 的启动类
//   Sources/YeTermKit/  → 真正的代码全在这个"库"里,类比业务 jar 模块
//   把逻辑放库里是为了以后能被测试/多目标复用,可执行壳越薄越好。
//
// 语法看点:
//   `import YeTermKit` —— 导入我们自己的库模块(类比 Java 的 import 包)。
//   `CommandLine.arguments` —— 命令行参数数组,含程序名,类比 Java 的 args
//     (区别:Swift 的第 0 个元素是程序路径,Java 的 args 不含)。
//   `exit(...)` —— 以指定退出码结束进程;0 = 成功,非 0 = 出错(shell 惯例)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import YeTermKit

// 【学】把参数交给 YeTermCLI.main 分发(它决定进 GUI 还是跑某个自测命令),
//      返回值直接当进程退出码 —— 下一站请读 App/YeTermCLI.swift
exit(YeTermCLI.main(CommandLine.arguments))
