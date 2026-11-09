import Foundation
import Testing
@testable import MitateCore

struct ClientTests {
  func home() throws -> Paths {
    let paths = Paths(home: FileManager.default.temporaryDirectory.appendingPathComponent("mitate-home-\(UUID().uuidString)", isDirectory: true))
    try paths.prepare()
    return paths
  }

  /// 使っていない port。開いてすぐ閉じる。
  func closedPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    try withUnsafeMutablePointer(to: &addr) { p in
      try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        guard bind(fd, sa, len) == 0, getsockname(fd, sa, &len) == 0 else { throw ClientError("port を得られない") }
      }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
  }

  @Test func noServerFileMeansNotRunning() async throws {
    #expect(try await AppClient.running(try home()) == nil)
  }

  /// 落ちたアプリが残した server.json の pid が、別のプロセス（ここでは launchd）に使い回されている場合。
  @Test func leftoverServerFileWithLivePidIsNotRunning() async throws {
    let paths = try home()
    let info = ServerInfo(port: try closedPort(), token: "stale", pid: 1)
    try JSONEncoder().encode(info).write(to: paths.serverInfo)
    #expect(try await AppClient.running(paths) == nil)
  }
}
