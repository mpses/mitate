import Foundation
import Testing
@testable import MitateCore

/// 起動中のアプリの代わり。live の検索では、手元の結果に無い Shot をサイトから返す。
final class FakeAPI: MitateAPI, @unchecked Sendable {
  var local: [ShotView] = [sample("a:1", title: "Toggle"), sample("b:2", title: "Switch")]
  var live: [ShotView] = [sample("pinterest:9", title: "Pin toggle")]
  var searches: [Bool] = []
  var shots: [String: ShotView] = [:]
  var selected: [ShotView] = []
  var sheets: [[String]] = []
  /// 入れておくと sources がこの例外で失敗する。起動し直す前のアプリの代わり
  var failure: Error?

  func sources() async throws -> [SourceStatus] {
    if let failure { throw failure }
    return [SourceStatus(id: "a", name: "Site A", home: "https://a.example/", icon: nil, canList: true, canSearch: false, login: .none, count: 1, sync: .idle, lastSyncedAt: nil)]
  }
  func search(_ query: String, sources: [String]?, kinds: [ShotKind]?, limit: Int, live: Bool) -> AsyncThrowingStream<SearchEvent, Error> {
    searches.append(live)
    let localNow = local
    let liveNow = self.live
    return AsyncThrowingStream { c in
      c.yield(.local(shots: localNow))
      if live {
        c.yield(.live(source: "pinterest", shots: liveNow))
        c.yield(.error(source: "x", message: "ログインしていない"))
      }
      c.yield(.done)
      c.finish()
    }
  }
  func similar(id: String, sources: [String]?, kinds: [ShotKind]?, limit: Int) async throws -> [ShotView] { [sample("b:2")] }
  func similar(image: Data, mimeType: String, sources: [String]?, kinds: [ShotKind]?, limit: Int) async throws -> [ShotView] { [sample("b:3")] }
  func shot(_ id: String) async throws -> ShotView {
    guard let shot = shots[id] else { throw ClientError("HTTP 404: \(id) は手元に無い") }
    return shot
  }
  func selection() async throws -> [ShotView] { selected }
  func sync(source: String?) async throws {}
  func sheet(ids: [String]) async throws -> Data {
    sheets.append(ids)
    return Data("sheet:\(ids.joined(separator: ","))".utf8)
  }
  func frames(id: String, count: Int) async throws -> (jpeg: Data, times: [Int]) {
    shots[id]?.media?.src.hasSuffix(".m3u8") == true ? (Data([1]), [0]) : (Data([2]), (0 ..< count).map { $0 * 500 })
  }
  func view(id: String) async throws -> Data { Data([3]) }
}

struct MCPTests {
  let api = FakeAPI()
  let server: MCPServer

  init() {
    let api = api
    server = MCPServer(connect: { api })
  }

  func call(_ method: String, _ params: JSONValue = .object([:]), id: JSONValue = .int(1)) async throws -> JSONValue {
    let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": params])
    let reply = try #require(await server.handle(try JSONEncoder().encode(request)))
    return try JSONDecoder().decode(JSONValue.self, from: reply)
  }

  func tool(_ name: String, _ args: [String: JSONValue]) async throws -> (content: [JSONValue], isError: Bool) {
    let reply = try await call("tools/call", .object(["name": .string(name), "arguments": .object(args)]))
    let result = try #require(reply["result"])
    return (try #require(result["content"]?.array), result["isError"]?.bool ?? false)
  }

  @Test func initializeEchoesProtocolVersion() async throws {
    let reply = try await call("initialize", .object(["protocolVersion": .string("2025-03-26"), "capabilities": .object([:])]), id: .string("init"))
    #expect(reply["id"] == .string("init"))
    #expect(reply["result"]?["protocolVersion"] == .string("2025-03-26"))
    #expect(reply["result"]?["capabilities"]?["tools"] != nil)
    #expect(try await call("ping")["result"] == .object([:]))
  }

  @Test func notificationsGetNoReply() async throws {
    let note = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])
    #expect(await server.handle(try JSONEncoder().encode(note)) == nil)
    let bad = try #require(await server.handle(Data("{nope".utf8)))
    #expect(try JSONDecoder().decode(JSONValue.self, from: bad)["error"]?["code"] == .int(-32700))
    #expect(try await call("resources/list")["error"]?["code"] == .int(-32601))
  }

  @Test func toolsListDescribesFiveTools() async throws {
    let tools = try #require(try await call("tools/list")["result"]?["tools"]?.array)
    #expect(tools.compactMap { $0["name"]?.string } == ["search", "similar", "view", "selection", "sources"])
    for tool in tools {
      #expect(tool["inputSchema"]?["type"] == .string("object"))
      #expect((tool["description"]?.string?.count ?? 0) > 40)
    }
    #expect(tools[0]["inputSchema"]?["required"] == .array([.string("query")]))
  }

  @Test func searchPutsTheSheetFirstAndMergesLive() async throws {
    let (content, isError) = try await tool("search", ["query": .string("toggle"), "limit": .int(10)])
    #expect(!isError)
    #expect(content.count == 2)
    #expect(content[0]["type"] == .string("image"))
    #expect(content[0]["mimeType"] == .string("image/jpeg"))
    let sheet = String(decoding: Data(base64Encoded: content[0]["data"]?.string ?? "") ?? Data(), as: UTF8.self)
    // 引き直した手元の 1 位、サイトの 1 位、手元の 2 位の順に RRF でまとまる。
    #expect(sheet == "sheet:a:1,pinterest:9,b:2")
    #expect(api.searches == [true, false])
    let text = try #require(content[1]["text"]?.string)
    #expect(text.contains("1. Toggle"))
    #expect(text.contains("Site A（a）"))
    #expect(text.contains("id: pinterest:9"))
    #expect(text.contains("x には問い合わせられなかった"))
  }

  @Test func searchWithoutLiveAsksOnce() async throws {
    _ = try await tool("search", ["query": .string("toggle"), "live": .bool(false), "kind": .string("video")])
    #expect(api.searches == [false])
  }

  @Test func emptyResultsAreSaidInText() async throws {
    api.local = []
    api.live = []
    let (content, isError) = try await tool("search", ["query": .string("zzz"), "live": .bool(false)])
    #expect(!isError)
    #expect(content.count == 1)
    #expect(content[0]["text"]?.string?.contains("当たる Shot は無かった") == true)
  }

  @Test func argumentErrorsAreToolErrors() async throws {
    #expect(try await tool("search", [:]).isError)
    #expect(try await tool("search", ["query": .string("a"), "limit": .int(41)]).isError)
    #expect(try await tool("search", ["query": .string("a"), "kind": .string("gif")]).isError)
    #expect(try await tool("similar", [:]).isError)
    #expect(try await tool("similar", ["id": .string("a:1"), "image_path": .string("/tmp/x.png")]).isError)
    #expect(try await tool("similar", ["image_path": .string("/nonexistent/x.png")]).isError)
    let unknown = try await call("tools/call", .object(["name": .string("delete"), "arguments": .object([:])]))
    #expect(unknown["error"]?["code"] == .int(-32602))
  }

  @Test func viewDescribesEachKind() async throws {
    api.shots["v:hls"] = sample("v:hls", kind: .video, src: "https://cdn.example/a.m3u8")
    api.shots["v:mp4"] = sample("v:mp4", kind: .video, src: "https://cdn.example/a.mp4")
    api.shots["t:1"] = sample("t:1", kind: .text, title: "記事", text: "冒頭の本文")
    let hls = try await tool("view", ["id": .string("v:hls")])
    #expect(hls.content[0]["type"] == .string("image"))
    #expect(hls.content[1]["text"]?.string?.contains("HLS の動画なのでフレームを取れなかった") == true)
    let mp4 = try await tool("view", ["id": .string("v:mp4")])
    #expect(mp4.content[1]["text"]?.string?.contains("8: 3.5 秒") == true)
    let text = try await tool("view", ["id": .string("t:1")])
    #expect(text.content.count == 1)
    let body = try #require(text.content[0]["text"]?.string)
    #expect(body.contains("保存してある本文"))
    #expect(body.contains("全文とは限らない"))
    #expect(body.contains("https://site.example/t:1"))
    #expect(body.contains("冒頭の本文"))
    #expect(try await tool("view", ["id": .string("missing")]).isError)
  }

  @Test func sourcesAndSelection() async throws {
    let sources = try await tool("sources", [:])
    #expect(sources.content[0]["text"]?.string?.contains("Site A（id: a）: 1 件") == true)
    let selection = try await tool("selection", [:])
    #expect(selection.content[0]["text"]?.string?.contains("まだ何も選んでいない") == true)
  }

  @Test func selectionLongerThanTheSheetListsEverything() async throws {
    api.selected = (1 ... 66).map { sample("a:\($0)", title: "選んだもの \($0)") }
    let (content, isError) = try await tool("selection", [:])
    #expect(!isError)
    #expect(content[0]["type"] == .string("image"))
    #expect(api.sheets == [(1 ... 40).map { "a:\($0)" }])
    let text = try #require(content[1]["text"]?.string)
    #expect(text.contains("先頭 40 件"))
    #expect(text.contains("66. 選んだもの 66"))
    #expect(text.contains("id: a:66"))
  }
}

/// 起動し直したアプリへつなぎ直すこと。
struct MCPReconnectTests {
  final class Connector: @unchecked Sendable {
    var made: [FakeAPI] = []
    let lock = NSLock()
    func connect() -> FakeAPI {
      lock.withLock {
        let api = FakeAPI()
        // 1 つ目は、起動し直す前のアプリの port に向いている。
        if made.isEmpty { api.failure = URLError(.cannotConnectToHost) }
        made.append(api)
        return api
      }
    }
  }

  @Test func reconnectsOnceWhenTheAppWentAway() async throws {
    let connector = Connector()
    let server = MCPServer(connect: { connector.connect() })
    func sources() async throws -> JSONValue {
      let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"), "params": .object(["name": .string("sources"), "arguments": .object([:])])])
      return try JSONDecoder().decode(JSONValue.self, from: try #require(await server.handle(try JSONEncoder().encode(request))))
    }
    #expect(try await sources()["result"]?["isError"] == .bool(false))
    #expect(connector.made.count == 2)
    #expect(try await sources()["result"]?["isError"] == .bool(false))
    #expect(connector.made.count == 2)
  }

  @Test func onlyLostConnectionsAreRetried() {
    #expect(MCPServer.lostApp(URLError(.cannotConnectToHost)))
    #expect(MCPServer.lostApp(ClientError("HTTP 401: token が違う", status: 401)))
    #expect(!MCPServer.lostApp(ClientError("HTTP 404: 無い", status: 404)))
    #expect(!MCPServer.lostApp(URLError(.timedOut)))
  }
}
