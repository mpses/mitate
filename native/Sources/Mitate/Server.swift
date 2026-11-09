import Foundation
import MitateCore
import Network
import Security

/// 127.0.0.1 の空いたポートで HTTP/1.1 を受け、HTTPRouter へ渡す。
final class Server: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "mitate.http")
  private var router: HTTPRouter?
  /// 待ち受けの準備ができたことを一度だけ知らせるための印。`queue` の上でだけ触る
  private var announced = false

  private init(listener: NWListener) {
    self.listener = listener
  }

  /// 待ち受けを始め、実際のポートが決まったら `makeRouter` で経路を作る。
  static func start(makeRouter: @escaping @Sendable (Int) -> HTTPRouter) async throws -> (Server, Int) {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let server = Server(listener: try NWListener(using: parameters))
    let port: Int = try await withCheckedThrowingContinuation { continuation in
      server.listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          guard !server.announced, let port = server.listener.port?.rawValue else { return }
          server.announced = true
          server.router = makeRouter(Int(port))
          continuation.resume(returning: Int(port))
        case let .failed(error):
          if server.announced {
            log("http: 待ち受けが止まった \(error)")
          } else {
            server.announced = true
            continuation.resume(throwing: error)
          }
        default:
          break
        }
      }
      server.listener.newConnectionHandler = { connection in server.serve(connection) }
      server.listener.start(queue: server.queue)
    }
    return (server, port)
  }

  private func serve(_ connection: NWConnection) {
    guard let router else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    Task { await Self.loop(connection, router: router) }
  }

  /// 1 本の接続で、要求を読んで答えることを繰り返す。stream の応答か `Connection: close` で閉じる。
  private static func loop(_ connection: NWConnection, router: HTTPRouter) async {
    defer { connection.cancel() }
    var buffer = Data()
    do {
      while true {
        switch HTTPParser.parse(buffer) {
        case .incomplete:
          guard let chunk = try await receive(connection) else { return }
          buffer.append(chunk)
        case let .invalid(status, message):
          let response = HTTPResponse.error(status, message)
          try await send(connection, response.head(keepAlive: false) + (response.data ?? Data()))
          return
        case let .complete(request, consumed):
          buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumed)
          let response = await router.respond(request)
          let keepAlive = request.keepAlive
          switch response.body {
          case let .data(body):
            try await send(connection, response.head(keepAlive: keepAlive) + body)
            if !keepAlive { return }
          case let .stream(produce):
            try await send(connection, response.head(keepAlive: false))
            do {
              try await produce { try await send(connection, $0) }
            } catch {
              // 途中で失敗した stream は done を書かずに閉じる。受け手は done が無いことで失敗を知る。
              log("http: \(request.path) の応答を途中で打ち切った: \(error)")
            }
            return
          }
        }
      }
    } catch {
      log("http: 接続を閉じた: \(error)")
    }
  }

  /// 届いた分。相手が閉じたら nil。
  private static func receive(_ connection: NWConnection) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(returning: nil)
        } else {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  private static func send(_ connection: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  func stop() {
    listener.cancel()
  }
}

/// `server.json` を権限 0600 で書く。中身を書き終えてから名前を付け替えるので、読み手が途中の状態を見ることは無い。
enum ServerFile {
  static func write(_ info: ServerInfo, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(info)
    let temp = file.deletingLastPathComponent().appendingPathComponent(".server.json.\(info.pid)")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { throw ClientError("\(temp.path) を作れない: \(String(cString: strerror(errno)))") }
    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    close(fd)
    guard written == data.count else { throw ClientError("\(temp.path) に書き切れない") }
    guard rename(temp.path, file.path) == 0 else { throw ClientError("\(file.path) へ名前を付け替えられない: \(String(cString: strerror(errno)))") }
  }

  /// 自分が書いたものだけを消す。
  static func remove(_ file: URL, pid: Int32) {
    guard let data = FileManager.default.contents(atPath: file.path), let info = try? JSONDecoder().decode(ServerInfo.self, from: data), info.pid == pid else { return }
    unlink(file.path)
  }

  static func token() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ClientError("token の乱数を作れない") }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}
