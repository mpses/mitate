import Foundation
import MitateCore

/// `Mitate mcp`。標準入力の 1 行を 1 件の JSON-RPC として読み、答えを標準出力へ 1 行ずつ書く。
/// 時間のかかる search の間も ping に答えられるよう、要求ごとに並行して処理する。
enum MCPCommand {
  static func run() async -> Int32 {
    let paths: Paths
    do {
      paths = try Paths.resolveHome()
    } catch {
      fputs("Mitate mcp: \(error)\n", stderr)
      return 1
    }
    let server = MCPServer(connect: { try await AppClient.connect(paths: paths) })
    let output = Output()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        var line = Data()
        for try await byte in FileHandle.standardInput.bytes {
          guard byte == 0x0A else {
            line.append(byte)
            continue
          }
          let request = line
          line = Data()
          guard request.contains(where: { !Set<UInt8>([0x20, 0x09, 0x0D]).contains($0) }) else { continue }
          group.addTask {
            if let reply = await server.handle(request) { await output.write(reply) }
          }
        }
        try await group.waitForAll()
      }
    } catch {
      fputs("Mitate mcp: 標準入力を読めない: \(error)\n", stderr)
      return 1
    }
    return 0
  }

  private actor Output {
    func write(_ data: Data) {
      FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
  }
}
