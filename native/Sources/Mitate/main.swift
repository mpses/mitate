import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

// Finder から開いたときに macOS が付けることのある引数は、引数なしと同じに扱う。
switch arguments.first.flatMap({ $0.hasPrefix("-psn_") ? nil : $0 }) {
case nil:
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
  }
case "probe":
  NSApplication.shared.setActivationPolicy(.prohibited)
  Task { @MainActor in
    exit(await Probe.run(Array(arguments.dropFirst())))
  }
  NSApplication.shared.run()
case "shoot":
  NSApplication.shared.setActivationPolicy(.prohibited)
  Task { @MainActor in
    exit(await Shoot.run(Array(arguments.dropFirst())))
  }
  NSApplication.shared.run()
case "dragcheck":
  NSApplication.shared.setActivationPolicy(.prohibited)
  Task { @MainActor in
    exit(await DragCheck.run(Array(arguments.dropFirst())))
  }
  NSApplication.shared.run()
case "fixtures":
  exit(Fixtures.run(Array(arguments.dropFirst())))
case "mcp":
  Task {
    exit(await MCPCommand.run())
  }
  dispatchMain()
case let command? where CLI.commands[command] != nil:
  Task {
    exit(await CLI.run(command, Array(arguments.dropFirst())))
  }
  dispatchMain()
default:
  fputs("""
    usage:
      Mitate                       アプリを起動する
      Mitate mcp                   stdio の MCP サーバー
    \(CLI.usage)
      Mitate probe <source.js> [--search <query>] [--pages <n>] [--out <shots.json>]
      \(Shoot.usage)
      \(DragCheck.usage)
      Mitate fixtures <out-dir> <shots.json>...

    """, stderr)
  exit(64)
}
