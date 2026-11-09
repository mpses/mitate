import Foundation
import Testing
@testable import MitateCore

func sample(_ id: String, kind: ShotKind = .image, title: String? = nil, src: String = "https://cdn.example/a.jpg", text: String? = nil) -> ShotView {
  ShotView(id: id, source: String(id.prefix { $0 != ":" }), url: "https://site.example/\(id)", origin: nil, kind: kind, title: title, text: text, tags: [],
           author: nil, publishedAt: nil, thumb: nil, media: kind == .text ? nil : ShotMedia(src: src, poster: nil, width: 100, height: 50),
           aspect: 2, colors: ["#112233"], duplicates: 1, selected: false, note: nil)
}

/// 経路と認証だけを確かめるための EngineAPI。呼ばれた引数を記録する。
final class FakeEngine: EngineAPI, @unchecked Sendable {
  var lastSearch: (query: String, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int, live: Bool)?
  var embedderReady = false
  let file: SourceFile

  init() throws {
    file = SourceFile(meta: try SourceFile.readMeta(id: "pinterest", code: """
      defineSource({ name: 'Pinterest', home: 'https://jp.pinterest.com/', login: { url: 'https://jp.pinterest.com/login/', check: async () => true },
        async search() { return { shots: [], next: null }; } });
      """), code: "", file: URL(fileURLWithPath: "/dev/null"))
  }

  func sources() async -> [SourceStatus] {
    [SourceStatus(id: "pinterest", name: "Pinterest", home: "https://jp.pinterest.com/", icon: nil, canList: false, canSearch: true, login: .signedOut, count: 3, sync: .idle, lastSyncedAt: nil)]
  }
  func browse(sources: Set<String>?, offset: Int, limit: Int) async throws -> [ShotView] { [sample("a:1")] }
  func search(_ query: String, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int, live: Bool) -> AsyncThrowingStream<SearchEvent, Error> {
    lastSearch = (query, sources, kinds, limit, live)
    return AsyncThrowingStream { c in
      c.yield(.local(shots: [sample("a:1", title: query)]))
      if live { c.yield(.error(source: "pinterest", message: "ログインしていない")) }
      c.yield(.done)
      c.finish()
    }
  }
  func similar(to target: SimilarTarget, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int) async throws -> [ShotView] {
    guard embedderReady else { throw EmbedderError.notConfigured }
    return [sample("a:2")]
  }
  func shot(_ id: String) async throws -> ShotView {
    guard id == "a:1" else { throw EngineError.notFound("\(id) は手元に無い") }
    return sample(id)
  }
  func selection() async throws -> [ShotView] { [] }
  func setSelection(_ id: String, _ update: SelectionUpdate) async throws -> ShotView {
    var v = sample(id)
    v.selected = update.selected
    v.note = update.note
    return v
  }
  func clearSelection() async throws {}
  func sync(source: String?) async {}
  func signInChanged(source: String) async {}
  func sheet(ids: [String]) async throws -> Data { Data([0xFF, 0xD8]) }
  func frames(id: String, count: Int) async throws -> (jpeg: Data, times: [Int]) { (Data([0xFF, 0xD8]), (0 ..< count).map { $0 * 100 }) }
  func view(id: String) async throws -> Data { Data([0xFF, 0xD8]) }
  func mediaFile(key: String) -> URL? { nil }
  func source(_ id: String) -> SourceFile? { id == "pinterest" ? file : nil }
}

struct HTTPParserTests {
  @Test func parsesRequestLineHeadersQueryAndBody() throws {
    let raw = "POST /api/similar?limit=5&q=dark+mode%20ui&sources=a,b HTTP/1.1\r\nHost: 127.0.0.1:9\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"id\":\"x\"}!GET"
    guard case let .complete(request, consumed) = HTTPParser.parse(Data(raw.utf8)) else { Issue.record("解析できない"); return }
    #expect(request.method == "POST")
    #expect(request.path == "/api/similar")
    #expect(request.query == ["limit": "5", "q": "dark mode ui", "sources": "a,b"])
    #expect(request.headers["content-type"] == "application/json")
    #expect(String(decoding: request.body, as: UTF8.self) == "{\"id\":\"x\"}!")
    #expect(consumed == raw.utf8.count - 3)
    #expect(request.keepAlive)
  }

  @Test func waitsForTheRestAndRejectsBadInput() {
    guard case .incomplete = HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) else { Issue.record("ヘッダーの途中"); return }
    guard case .incomplete = HTTPParser.parse(Data("PUT /a HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345".utf8)) else { Issue.record("本文の途中"); return }
    guard case .invalid(400, _) = HTTPParser.parse(Data("NONSENSE\r\n\r\n".utf8)) else { Issue.record("要求行が不正"); return }
    guard case .invalid(413, _) = HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: \(HTTPParser.maxBody + 1)\r\n\r\n".utf8)) else { Issue.record("本文が大きすぎる"); return }
    guard case .invalid(501, _) = HTTPParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else { Issue.record("chunked"); return }
    guard case let .complete(close, _) = HTTPParser.parse(Data("GET / HTTP/1.1\r\nConnection: close\r\n\r\n".utf8)) else { Issue.record("close"); return }
    #expect(!close.keepAlive)
  }

  @Test func streamHeadHasNoLengthAndCloses() {
    let head = String(decoding: HTTPResponse(status: 200, headers: [("Content-Type", "application/x-ndjson")], body: .stream { _ in }).head(keepAlive: true), as: UTF8.self)
    #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(head.contains("Connection: close"))
    #expect(!head.contains("Content-Length"))
    let plain = String(decoding: HTTPResponse.empty(204).head(keepAlive: true), as: UTF8.self)
    #expect(plain.contains("Content-Length: 0\r\n"))
    #expect(plain.contains("Connection: keep-alive"))
  }
}

struct HTTPRouterTests {
  let engine: FakeEngine
  let router: HTTPRouter
  let web: URL
  let opened = Recorder()

  final class Recorder: @unchecked Sendable {
    var logins: [String] = []
    var urls: [URL] = []
  }

  init() throws {
    engine = try FakeEngine()
    web = FileManager.default.temporaryDirectory.appendingPathComponent("mitate-web-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: web.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("<!doctype html>viewer".utf8).write(to: web.appendingPathComponent("index.html"))
    try Data("console.log(1)".utf8).write(to: web.appendingPathComponent("assets/app.js"))
    let opened = opened
    router = HTTPRouter(engine: engine, port: 4321, token: "secret", web: web, actions: HTTPActions(
      openLogin: { opened.logins.append($0) },
      openURL: { opened.urls.append($0) }
    ))
  }

  func get(_ target: String, host: String = "127.0.0.1:4321", token: String? = "secret", method: String = "GET", body: Data = Data(), type: String? = nil) async -> HTTPResponse {
    let (path, query) = HTTPParser.splitTarget(target)
    var headers = ["host": host]
    if let token { headers["authorization"] = "Bearer \(token)" }
    if let type { headers["content-type"] = type }
    return await router.respond(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
  }

  func text(_ r: HTTPResponse) -> String { String(decoding: r.data ?? Data(), as: UTF8.self) }

  @Test func hostAndTokenAreChecked() async {
    #expect(await get("/api/sources", host: "evil.example:4321").status == 403)
    #expect(await get("/api/sources", host: "127.0.0.1:9999").status == 403)
    #expect(await get("/", host: "evil.example").status == 403)
    #expect(await get("/api/sources", token: nil).status == 401)
    #expect(await get("/api/sources", token: "wrong").status == 401)
    #expect(await get("/api/sources", host: "localhost:4321").status == 200)
    // percent エンコードした `api` も API として token を要る。
    #expect(await get("/%61pi/sources", token: nil).status == 401)
    #expect(await get("/%61%70%69/open", token: nil, method: "POST", body: Data("{\"url\":\"https://a.example/x\"}".utf8), type: "text/plain").status == 401)
    #expect(opened.urls.isEmpty)
    #expect(await get("/%61pi/sources").status == 200)
    // ビューワーと /media/ は token なしで読める。
    #expect(await get("/", token: nil).status == 200)
    #expect(await get("/media/0000000000000000000000000000000000000000.jpg", token: nil).status == 404)
  }

  @Test func servesTheViewerAndRefusesTraversal() async {
    let index = await get("/", token: nil)
    #expect(index.header("Content-Type") == "text/html; charset=utf-8")
    #expect(text(index).contains("viewer"))
    #expect(await get("/assets/app.js", token: nil).header("Content-Type") == "text/javascript; charset=utf-8")
    #expect(await get("/../secret", token: nil).status == 404)
    #expect(await get("/assets/%2E%2E/%2E%2E/etc/passwd", token: nil).status == 404)
    #expect(await get("/missing.js", token: nil).status == 404)
  }

  @Test func searchStreamsNDJSONAndPassesFilters() async throws {
    let response = await get("/api/search?q=toggle&sources=a,pinterest&kinds=image,video&limit=7&live=1")
    #expect(response.status == 200)
    guard case let .stream(produce) = response.body else { Issue.record("stream ではない"); return }
    let collected = Collector()
    try await produce { collected.append($0) }
    let lines = String(decoding: collected.data, as: UTF8.self).split(separator: "\n")
    let events = try lines.map { try JSONDecoder().decode(SearchEvent.self, from: Data($0.utf8)) }
    #expect(events.count == 3)
    #expect(events.last == .done)
    let call = try #require(engine.lastSearch)
    #expect(call.query == "toggle")
    #expect(call.sources == ["a", "pinterest"])
    #expect(call.kinds == [.image, .video])
    #expect(call.limit == 7)
    #expect(call.live)
    #expect(await get("/api/search?q=x&kinds=gif").status == 400)
    #expect(await get("/api/search?q=x&live=yes").status == 400)
    #expect(await get("/api/search?q=x&limit=0").status == 400)
  }

  /// HTTP.md に書いた範囲の端は受け、外は 400 にする
  @Test func numericParametersStayInTheDocumentedRanges() async {
    #expect(await get("/api/browse?offset=0&limit=500").status == 200)
    #expect(await get("/api/browse?limit=501").status == 400)
    #expect(await get("/api/browse?offset=-1").status == 400)
    #expect(await get("/api/browse?limit=8.5").status == 400)
    #expect(await get("/api/frames/a%3A1?n=1").status == 200)
    #expect(await get("/api/frames/a%3A1?n=16").status == 200)
    #expect(await get("/api/frames/a%3A1?n=0").status == 400)
    #expect(await get("/api/frames/a%3A1?n=17").status == 400)
  }

  final class Collector: @unchecked Sendable {
    var data = Data()
    func append(_ d: Data) { data.append(d) }
  }

  @Test func errorsMapToStatuses() async {
    #expect(await get("/api/similar", method: "POST", body: Data("{\"id\":\"a:1\"}".utf8), type: "application/json").status == 503)
    engine.embedderReady = true
    #expect(await get("/api/similar", method: "POST", body: Data("{\"id\":\"a:1\"}".utf8), type: "application/json").status == 200)
    #expect(await get("/api/similar", method: "POST", body: Data([1, 2]), type: "image/png").status == 200)
    #expect(await get("/api/similar", method: "POST", body: Data("x".utf8), type: "text/plain").status == 415)
    #expect(await get("/api/shots/a%3A1").status == 200)
    #expect(await get("/api/shots/nope").status == 404)
    #expect(await get("/api/nothing").status == 404)
    #expect(await get("/api/sources", method: "DELETE").status == 404)
  }

  @Test func actionsAndBodies() async throws {
    #expect(await get("/api/login?source=pinterest", method: "POST").status == 202)
    #expect(opened.logins == ["pinterest"])
    #expect(await get("/api/login?source=nope", method: "POST").status == 404)
    #expect(await get("/api/sync?source=pinterest", method: "POST").status == 400)
    #expect(await get("/api/sync", method: "POST").status == 202)
    #expect(await get("/api/open", method: "POST", body: Data("{\"url\":\"https://a.example/x\"}".utf8), type: "application/json").status == 204)
    #expect(await get("/api/open", method: "POST", body: Data("{\"url\":\"file:///etc/passwd\"}".utf8), type: "application/json").status == 400)
    #expect(opened.urls == [URL(string: "https://a.example/x")!])
    let put = await get("/api/selection/a%3A9", method: "PUT", body: Data("{\"selected\":true,\"note\":\"余白\"}".utf8), type: "application/json")
    #expect(put.status == 200)
    #expect(try JSONDecoder().decode(ShotView.self, from: put.data ?? Data()).note == "余白")
    #expect(await get("/api/selection/a%3A9", method: "PUT", body: Data("{}".utf8)).status == 400)
    #expect(await get("/api/selection", method: "DELETE").status == 204)
    let frames = await get("/api/frames/a%3A1?n=3")
    #expect(frames.header("X-Frame-Times") == "0,100,200")
    #expect(await get("/api/frames/a%3A1?n=99").status == 400)
    #expect(await get("/api/sheet").status == 400)
    #expect(await get("/api/sheet?ids=a:1,a:2").header("Content-Type") == "image/jpeg")
  }
}
