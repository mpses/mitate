import Foundation

// HTTP/1.1 の要求の解析、認証、経路。待ち受け（NWListener）はアプリ側が持ち、ここは入力だけで結果が決まる。

public struct HTTPRequest: Sendable {
  public var method: String
  /// クエリを除いた、デコード前のパス
  public var path: String
  public var query: [String: String]
  /// 名前は小文字
  public var headers: [String: String]
  public var body: Data

  public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
    self.method = method
    self.path = path
    self.query = query
    self.headers = headers
    self.body = body
  }

  /// `Connection: close` が無ければ、同じ接続で次の要求を待つ。
  public var keepAlive: Bool {
    headers["connection"]?.lowercased() != "close"
  }
}

public enum HTTPParseResult: Sendable {
  /// まだ要求の終わりまで届いていない
  case incomplete
  case complete(HTTPRequest, consumed: Int)
  case invalid(status: Int, message: String)
}

public enum HTTPParser {
  public static let maxHeader = 64 * 1024
  public static let maxBody = 20 * 1024 * 1024

  /// 先頭の 1 件を読む。本文は `Content-Length` の分だけ。
  public static func parse(_ buffer: Data) -> HTTPParseResult {
    let terminator = Data("\r\n\r\n".utf8)
    guard let end = buffer.range(of: terminator) else {
      return buffer.count > maxHeader ? .invalid(status: 431, message: "ヘッダーが大きすぎる") : .incomplete
    }
    let headEnd = end.lowerBound - buffer.startIndex
    guard headEnd <= maxHeader else { return .invalid(status: 431, message: "ヘッダーが大きすぎる") }
    guard let head = String(data: buffer[buffer.startIndex ..< end.lowerBound], encoding: .utf8) else {
      return .invalid(status: 400, message: "ヘッダーが UTF-8 ではない")
    }
    var lines = head.components(separatedBy: "\r\n")
    let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty, parts[1].hasPrefix("/") else {
      return .invalid(status: 400, message: "要求行が不正")
    }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400, message: "ヘッダーの行が不正: \(line.prefix(80))") }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { return .invalid(status: 400, message: "ヘッダー名が空") }
      headers[name] = headers[name].map { "\($0), \(value)" } ?? value
    }
    if headers["transfer-encoding"] != nil { return .invalid(status: 501, message: "Transfer-Encoding には対応していない") }
    var length = 0
    if let text = headers["content-length"] {
      guard let n = Int(text), n >= 0 else { return .invalid(status: 400, message: "Content-Length が不正") }
      guard n <= maxBody else { return .invalid(status: 413, message: "本文が \(maxBody) バイトを超える") }
      length = n
    }
    let bodyStart = end.upperBound
    guard buffer.endIndex - bodyStart >= length else { return .incomplete }
    let target = String(parts[1])
    let (path, query) = splitTarget(target)
    let request = HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: Data(buffer[bodyStart ..< bodyStart + length]))
    return .complete(request, consumed: bodyStart + length - buffer.startIndex)
  }

  /// パスとクエリに分ける。クエリの値は `+` を空白として percent デコードする。
  static func splitTarget(_ target: String) -> (String, [String: String]) {
    guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
    var query: [String: String] = [:]
    for pair in target[target.index(after: mark)...].split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      func decode(_ s: Substring) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
      }
      query[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
    }
    return (String(target[..<mark]), query)
  }
}

public struct HTTPResponse: Sendable {
  public typealias Writer = @Sendable (Data) async throws -> Void

  public enum Body: Sendable {
    case data(Data)
    /// 長さを決めずに書き、書き終えたら接続を閉じる
    case stream(@Sendable (_ write: Writer) async throws -> Void)
  }

  public var status: Int
  public var headers: [(String, String)]
  public var body: Body

  public init(status: Int, headers: [(String, String)] = [], body: Body = .data(Data())) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  public var data: Data? {
    if case let .data(d) = body { return d }
    return nil
  }

  public func header(_ name: String) -> String? {
    headers.first { $0.0.lowercased() == name.lowercased() }?.1
  }

  static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }()

  public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
    HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: .data(try encoder.encode(value)))
  }

  public static func error(_ status: Int, _ message: String) -> HTTPResponse {
    struct Failure: Encodable { let error: String }
    // 文字列 1 つの構造体の encode は失敗しない。
    let body = try! encoder.encode(Failure(error: message))
    return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: .data(body))
  }

  public static func empty(_ status: Int) -> HTTPResponse {
    HTTPResponse(status: status)
  }

  /// 状態行とヘッダー。`stream` は `Connection: close` で長さを付けない。
  public func head(keepAlive: Bool) -> Data {
    var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
    lines += headers.map { "\($0.0): \($0.1)" }
    switch body {
    case let .data(d):
      lines.append("Content-Length: \(d.count)")
      lines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
    case .stream:
      lines.append("Connection: close")
    }
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
  }

  static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 202: "Accepted"
    case 204: "No Content"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 413: "Payload Too Large"
    case 415: "Unsupported Media Type"
    case 431: "Request Header Fields Too Large"
    case 500: "Internal Server Error"
    case 501: "Not Implemented"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    default: "Status"
    }
  }
}

/// アプリの窓が受け持つ操作。
public struct HTTPActions: Sendable {
  public var openLogin: @Sendable (String) async -> Void
  public var openURL: @Sendable (URL) async -> Void

  public init(openLogin: @escaping @Sendable (String) async -> Void, openURL: @escaping @Sendable (URL) async -> Void) {
    self.openLogin = openLogin
    self.openURL = openURL
  }
}

/// HTTP.md の経路。Host と token を確かめてから EngineAPI へ渡す。
public final class HTTPRouter: Sendable {
  let engine: EngineAPI
  let port: Int
  let token: String
  let web: URL
  let actions: HTTPActions

  public init(engine: EngineAPI, port: Int, token: String, web: URL, actions: HTTPActions) {
    self.engine = engine
    self.port = port
    self.token = token
    self.web = web.standardizedFileURL
    self.actions = actions
  }

  /// Host が自分のポートでなければ 403、`/api/` に token が無いか違えば 401。
  /// token が要るかどうかは、振り分けと同じ、percent デコードした区間で決める（`/%61pi/` も `/api/` に届くため）。
  public func respond(_ request: HTTPRequest) async -> HTTPResponse {
    guard let host = request.headers["host"], host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
      return .error(403, "Host が 127.0.0.1:\(port) か localhost:\(port) ではない")
    }
    do {
      let segments = try Self.segments(request.path)
      if segments.first == "api" {
        guard let auth = request.headers["authorization"], Self.constantTimeEqual(auth, "Bearer \(token)") else {
          return .error(401, "Authorization: Bearer <token> が無いか、token が違う")
        }
      }
      return try await route(request, segments)
    } catch let error as RouteError {
      return .error(error.status, error.message)
    } catch {
      return .error(Self.status(for: error), "\(error)")
    }
  }

  /// 先頭の `/` を除いたパスの区間。各区間を percent デコードする。
  static func segments(_ path: String) throws -> [String] {
    try path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { part in
      guard let decoded = String(part).removingPercentEncoding else { throw RouteError(status: 400, message: "パスの percent エンコードが不正") }
      return decoded
    }
  }

  static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  static func status(for error: Error) -> Int {
    switch error {
    case EngineError.notFound: 404
    case EngineError.badRequest: 400
    case EngineError.unavailable, EmbedderError.notConfigured: 503
    case is MediaError: 502
    default: 500
    }
  }

  struct RouteError: Error {
    let status: Int
    let message: String
  }

  private func route(_ r: HTTPRequest, _ segments: [String]) async throws -> HTTPResponse {
    switch (r.method, segments.first) {
    case (_, "api"): return try await api(r, Array(segments.dropFirst()))
    case ("GET", "media"):
      guard segments.count == 2, let file = engine.mediaFile(key: segments[1]) else { throw RouteError(status: 404, message: "\(r.path) は無い") }
      return HTTPResponse(status: 200, headers: [("Content-Type", Self.contentType(file.pathExtension)), ("Cache-Control", "max-age=86400")], body: .data(try Data(contentsOf: file)))
    case ("GET", _): return try staticFile(segments)
    default: throw RouteError(status: 405, message: "\(r.method) \(r.path) は受け付けない")
    }
  }

  private func api(_ r: HTTPRequest, _ s: [String]) async throws -> HTTPResponse {
    switch (r.method, s.first, s.count) {
    case ("GET", "sources", 1):
      return try .json(SourcesResponse(sources: await engine.sources()))
    case ("GET", "browse", 1):
      let shots = try await engine.browse(sources: sources(r), offset: try int(r, "offset", default: 0, range: 0 ... Int.max), limit: try limit(r))
      return try .json(ShotsResponse(shots: shots))
    case ("GET", "search", 1):
      let events = engine.search(r.query["q"] ?? "", sources: sources(r), kinds: try kinds(r), limit: try limit(r), live: try flag(r, "live"))
      return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-ndjson; charset=utf-8"), ("Cache-Control", "no-store")], body: .stream { write in
        for try await event in events {
          try await write(try HTTPResponse.encoder.encode(event) + Data("\n".utf8))
        }
      })
    case ("POST", "similar", 1):
      let target: SimilarTarget
      let type = (r.headers["content-type"] ?? "").lowercased()
      if type.hasPrefix("image/") {
        guard !r.body.isEmpty else { throw RouteError(status: 400, message: "画像の本文が空") }
        target = .image(r.body)
      } else if type.hasPrefix("application/json") {
        struct Body: Decodable { let id: String }
        target = .shot(try decode(Body.self, r.body).id)
      } else {
        throw RouteError(status: 415, message: "本文は application/json の { \"id\" } か image/*")
      }
      return try .json(ShotsResponse(shots: try await engine.similar(to: target, sources: sources(r), kinds: try kinds(r), limit: try limit(r))))
    case ("GET", "shots", 2):
      return try .json(try await engine.shot(s[1]))
    case ("GET", "selection", 1):
      return try .json(ShotsResponse(shots: try await engine.selection()))
    case ("PUT", "selection", 2):
      return try .json(try await engine.setSelection(s[1], try decode(SelectionUpdate.self, r.body)))
    case ("DELETE", "selection", 1):
      try await engine.clearSelection()
      return .empty(204)
    case ("POST", "sync", 1):
      if let id = r.query["source"] {
        guard let file = engine.source(id) else { throw RouteError(status: 404, message: "サイト \(id) は無い") }
        guard file.meta.canList else { throw RouteError(status: 400, message: "\(id) は list を持たないので取得するものが無い") }
      }
      await engine.sync(source: r.query["source"])
      return .empty(202)
    case ("POST", "login", 1):
      guard let id = r.query["source"] else { throw RouteError(status: 400, message: "source が無い") }
      guard let file = engine.source(id) else { throw RouteError(status: 404, message: "サイト \(id) は無い") }
      guard file.meta.loginURL != nil else { throw RouteError(status: 400, message: "\(id) はログインが要らない") }
      await actions.openLogin(id)
      return .empty(202)
    case ("POST", "open", 1):
      struct Body: Decodable { let url: String }
      let text = try decode(Body.self, r.body).url
      guard isHTTP(text), let url = URL(string: text) else { throw RouteError(status: 400, message: "url が http(s) の絶対 URL ではない: \(text)") }
      await actions.openURL(url)
      return .empty(204)
    case ("GET", "sheet", 1):
      let ids = (r.query["ids"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
      guard !ids.isEmpty else { throw RouteError(status: 400, message: "ids が無い") }
      guard ids.count <= Sheets.maxCount else { throw RouteError(status: 400, message: "ids は \(Sheets.maxCount) 件まで") }
      return jpeg(try await engine.sheet(ids: ids))
    case ("GET", "frames", 2):
      let result = try await engine.frames(id: s[1], count: try int(r, "n", default: 8, range: 1 ... 16))
      var response = jpeg(result.jpeg)
      response.headers.append(("X-Frame-Times", result.times.map(String.init).joined(separator: ",")))
      return response
    case ("GET", "view", 2):
      return jpeg(try await engine.view(id: s[1]))
    default:
      throw RouteError(status: 404, message: "\(r.method) \(r.path) は無い")
    }
  }

  private func jpeg(_ data: Data) -> HTTPResponse {
    HTTPResponse(status: 200, headers: [("Content-Type", "image/jpeg"), ("Cache-Control", "no-store")], body: .data(data))
  }

  /// `/` は `index.html`。web の外を指すパスは 404。
  private func staticFile(_ segments: [String]) throws -> HTTPResponse {
    let parts = segments.filter { !$0.isEmpty }
    guard !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") || $0.contains("/") }) else { throw RouteError(status: 404, message: "無い") }
    let file = (parts.isEmpty ? web.appendingPathComponent("index.html") : parts.reduce(web) { $0.appendingPathComponent($1) }).standardizedFileURL
    var isDir: ObjCBool = false
    guard file.path.hasPrefix(web.path + "/"), FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
      throw RouteError(status: 404, message: "/\(parts.joined(separator: "/")) は無い")
    }
    return HTTPResponse(status: 200, headers: [("Content-Type", Self.contentType(file.pathExtension)), ("Cache-Control", "no-cache")], body: .data(try Data(contentsOf: file)))
  }

  static func contentType(_ ext: String) -> String {
    switch ext.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json", "map": "application/json; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "webp": "image/webp"
    case "gif": "image/gif"
    case "ico": "image/x-icon"
    case "woff2": "font/woff2"
    case "woff": "font/woff"
    case "ttf": "font/ttf"
    case "otf": "font/otf"
    case "wasm": "application/wasm"
    case "txt": "text/plain; charset=utf-8"
    default: "application/octet-stream"
    }
  }

  // MARK: - クエリ

  private func sources(_ r: HTTPRequest) -> Set<String>? {
    guard let text = r.query["sources"], !text.isEmpty else { return nil }
    return Set(text.split(separator: ",").map(String.init))
  }

  private func kinds(_ r: HTTPRequest) throws -> Set<ShotKind>? {
    guard let text = r.query["kinds"], !text.isEmpty else { return nil }
    return Set(try text.split(separator: ",").map { name in
      guard let kind = ShotKind(rawValue: String(name)) else { throw RouteError(status: 400, message: "kinds は image・video・text のカンマ区切り: \(name)") }
      return kind
    })
  }

  private func limit(_ r: HTTPRequest) throws -> Int {
    try int(r, "limit", default: 80, range: 1 ... 500)
  }

  private func int(_ r: HTTPRequest, _ name: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
    guard let text = r.query[name], !text.isEmpty else { return value }
    guard let n = Int(text), range.contains(n) else { throw RouteError(status: 400, message: "\(name) は \(range.lowerBound)〜\(range.upperBound) の整数") }
    return n
  }

  private func flag(_ r: HTTPRequest, _ name: String) throws -> Bool {
    switch r.query[name] {
    case nil, "", "0", "false": return false
    case "1", "true": return true
    case let other?: throw RouteError(status: 400, message: "\(name) は 1 か 0: \(other)")
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: body)
    } catch {
      throw RouteError(status: 400, message: "本文の JSON が \(type) の形ではない: \(error)")
    }
  }
}
