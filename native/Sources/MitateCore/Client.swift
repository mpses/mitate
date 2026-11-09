import Foundation

/// 起動中のアプリへの問い合わせ。MCP と CLI はこの操作だけを使う。
public protocol MitateAPI: Sendable {
  func sources() async throws -> [SourceStatus]
  func search(_ query: String, sources: [String]?, kinds: [ShotKind]?, limit: Int, live: Bool) -> AsyncThrowingStream<SearchEvent, Error>
  func similar(id: String, sources: [String]?, kinds: [ShotKind]?, limit: Int) async throws -> [ShotView]
  func similar(image: Data, mimeType: String, sources: [String]?, kinds: [ShotKind]?, limit: Int) async throws -> [ShotView]
  func shot(_ id: String) async throws -> ShotView
  func selection() async throws -> [ShotView]
  func sync(source: String?) async throws
  func sheet(ids: [String]) async throws -> Data
  func frames(id: String, count: Int) async throws -> (jpeg: Data, times: [Int])
  func view(id: String) async throws -> Data
}

public struct ClientError: Error, CustomStringConvertible {
  public let message: String
  /// アプリが返した HTTP の状態。応答の前に失敗したときは nil
  public let status: Int?
  public init(_ message: String, status: Int? = nil) {
    self.message = message
    self.status = status
  }

  public var description: String { message }
}

/// `server.json` の port と token で、起動中のアプリへ HTTP で問い合わせる。
public final class AppClient: MitateAPI {
  public let info: ServerInfo
  private let session: URLSession

  public init(info: ServerInfo) {
    self.info = info
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 600
    session = URLSession(configuration: config)
  }

  /// 起動中のアプリへつなぐ。起動していなければ、自分を含む `.app` を `open -g -a` で起動し、最大 30 秒 `server.json` を待つ。
  public static func connect(paths: Paths, bundle: Bundle = .main) async throws -> AppClient {
    if let info = try await running(paths) { return AppClient(info: info) }
    guard bundle.bundleURL.pathExtension == "app" else {
      throw ClientError("Mitate が起動していない（\(paths.serverInfo.path) が無いか、そこに書かれた port で Mitate が答えない）。.app の外で動いているので自動では起動できない。先にアプリを起動する")
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-a", bundle.bundleURL.path]
    try open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else { throw ClientError("open -g -a \(bundle.bundleURL.path) が終了コード \(open.terminationStatus) で失敗した") }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if let info = try await running(paths) { return AppClient(info: info) }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw ClientError("\(bundle.bundleURL.path) を起動したが、30 秒以内に \(paths.serverInfo.path) が現れなかった")
  }

  /// `server.json` があり、そこに書かれた port で Mitate が token を受け付けたときだけ接続情報を返す。
  /// 落ちたアプリが残した server.json の pid は別のプロセスに使い回されることがあるので、pid だけでは決めない。
  public static func running(_ paths: Paths) async throws -> ServerInfo? {
    guard FileManager.default.fileExists(atPath: paths.serverInfo.path) else { return nil }
    let info: ServerInfo
    do {
      info = try JSONDecoder().decode(ServerInfo.self, from: Data(contentsOf: paths.serverInfo))
    } catch {
      throw ClientError("\(paths.serverInfo.path) を読めない: \(error)")
    }
    // EPERM は別の利用者のプロセスが生きているという意味なので、port に問うて確かめる。
    guard kill(info.pid, 0) == 0 || errno == EPERM else { return nil }
    if let refusal = await probe(info) {
      log("\(paths.serverInfo.path) は残ったものとみなす（pid \(info.pid)、port \(info.port): \(refusal)）")
      return nil
    }
    return info
  }

  /// `/api/sources` に token 付きで問う。答えたら nil、答えなければその理由。
  static func probe(_ info: ServerInfo) async -> String? {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    guard let url = URL(string: "http://127.0.0.1:\(info.port)/api/sources") else { return "port \(info.port) で URL を組み立てられない" }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
    do {
      let (_, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode
      return status == 200 ? nil : "HTTP \(status.map(String.init) ?? "以外の応答")"
    } catch {
      return error.localizedDescription
    }
  }

  // MARK: - MitateAPI

  public func sources() async throws -> [SourceStatus] {
    try await json(SourcesResponse.self, "GET", "/api/sources").sources
  }

  public func search(_ query: String, sources: [String]?, kinds: [ShotKind]?, limit: Int, live: Bool) -> AsyncThrowingStream<SearchEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var items = [("q", query), ("limit", String(limit)), ("live", live ? "1" : "0")]
          items += self.filters(sources: sources, kinds: kinds)
          let (bytes, raw) = try await self.session.bytes(for: self.request("GET", "/api/search", query: items))
          guard let response = raw as? HTTPURLResponse else { throw ClientError("/api/search の応答が HTTP ではない") }
          guard response.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw Self.failure(response.statusCode, body)
          }
          var finished = false
          for try await line in bytes.lines where !line.isEmpty {
            let event = try JSONDecoder().decode(SearchEvent.self, from: Data(line.utf8))
            continuation.yield(event)
            if case .done = event { finished = true }
          }
          guard finished else { throw ClientError("/api/search の応答が done の前に切れた") }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func similar(id: String, sources: [String]?, kinds: [ShotKind]?, limit: Int) async throws -> [ShotView] {
    struct Body: Encodable { let id: String }
    let query = [("limit", String(limit))] + filters(sources: sources, kinds: kinds)
    return try await json(ShotsResponse.self, "POST", "/api/similar", query: query, body: try JSONEncoder().encode(Body(id: id)), type: "application/json").shots
  }

  public func similar(image: Data, mimeType: String, sources: [String]?, kinds: [ShotKind]?, limit: Int) async throws -> [ShotView] {
    let query = [("limit", String(limit))] + filters(sources: sources, kinds: kinds)
    return try await json(ShotsResponse.self, "POST", "/api/similar", query: query, body: image, type: mimeType).shots
  }

  public func shot(_ id: String) async throws -> ShotView {
    try await json(ShotView.self, "GET", "/api/shots/\(Self.segment(id))")
  }

  public func selection() async throws -> [ShotView] {
    try await json(ShotsResponse.self, "GET", "/api/selection").shots
  }

  public func sync(source: String?) async throws {
    _ = try await send("POST", "/api/sync", query: source.map { [("source", $0)] } ?? [])
  }

  public func sheet(ids: [String]) async throws -> Data {
    try await send("GET", "/api/sheet", query: [("ids", ids.joined(separator: ","))]).0
  }

  public func frames(id: String, count: Int) async throws -> (jpeg: Data, times: [Int]) {
    let (data, response) = try await send("GET", "/api/frames/\(Self.segment(id))", query: [("n", String(count))])
    guard let header = response.value(forHTTPHeaderField: "X-Frame-Times") else { throw ClientError("/api/frames の応答に X-Frame-Times が無い") }
    let times = try header.split(separator: ",").map { part -> Int in
      guard let n = Int(part) else { throw ClientError("X-Frame-Times が整数のカンマ区切りではない: \(header)") }
      return n
    }
    return (data, times)
  }

  public func view(id: String) async throws -> Data {
    try await send("GET", "/api/view/\(Self.segment(id))").0
  }

  // MARK: - HTTP

  private func filters(sources: [String]?, kinds: [ShotKind]?) -> [(String, String)] {
    var items: [(String, String)] = []
    if let sources { items.append(("sources", sources.joined(separator: ","))) }
    if let kinds { items.append(("kinds", kinds.map(\.rawValue).joined(separator: ","))) }
    return items
  }

  private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

  static func segment(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: ":"))) ?? text
  }

  private func request(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, type: String? = nil) throws -> URLRequest {
    var text = "http://127.0.0.1:\(info.port)\(path)"
    if !query.isEmpty {
      // URLComponents は `+` を符号化しないので、値はすべて自前で percent 符号化する。
      text += "?" + query.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? $0.1)" }.joined(separator: "&")
    }
    guard let url = URL(string: text) else { throw ClientError("URL を組み立てられない: \(text)") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = body
      request.setValue(type, forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func send(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, type: String? = nil) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request(method, path, query: query, body: body, type: type))
    guard let http = response as? HTTPURLResponse else { throw ClientError("\(path) の応答が HTTP ではない") }
    guard (200 ..< 300).contains(http.statusCode) else { throw Self.failure(http.statusCode, data) }
    return (data, http)
  }

  private func json<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, type contentType: String? = nil) async throws -> T {
    let (data, _) = try await send(method, path, query: query, body: body, type: contentType)
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw ClientError("\(path) の応答が \(type) の形ではない: \(error)")
    }
  }

  private static func failure(_ status: Int, _ body: Data) -> ClientError {
    struct Failure: Decodable { let error: String }
    let message = (try? JSONDecoder().decode(Failure.self, from: body).error) ?? String(decoding: body.prefix(300), as: UTF8.self)
    return ClientError("HTTP \(status): \(message)", status: status)
  }
}
