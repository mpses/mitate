import Foundation
import UniformTypeIdentifiers

/// JSON-RPC の任意の値。
public enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Int.self) { self = .int(v) }
    else if let v = try? c.decode(Double.self) { self = .double(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case let .bool(v): try c.encode(v)
    case let .int(v): try c.encode(v)
    case let .double(v): try c.encode(v)
    case let .string(v): try c.encode(v)
    case let .array(v): try c.encode(v)
    case let .object(v): try c.encode(v)
    }
  }

  public subscript(key: String) -> JSONValue? {
    if case let .object(o) = self { return o[key] }
    return nil
  }

  public var string: String? {
    if case let .string(s) = self { return s }
    return nil
  }

  public var int: Int? {
    switch self {
    case let .int(n): n
    case let .double(d) where d.rounded() == d: Int(d)
    default: nil
    }
  }

  public var bool: Bool? {
    if case let .bool(b) = self { return b }
    return nil
  }

  public var array: [JSONValue]? {
    if case let .array(a) = self { return a }
    return nil
  }
}

/// 改行区切りの JSON-RPC 2.0 で動く MCP サーバー。アプリへの接続は、最初のツール呼び出しまで遅らせる。
public final class MCPServer: Sendable {
  private let connection: Connection

  public init(connect: @escaping @Sendable () async throws -> MitateAPI) {
    connection = Connection(connect: connect)
  }

  /// アプリへの接続。アプリを起動し直すと port と token が変わるので、つながらなくなったら作り直す。
  private actor Connection {
    let connect: @Sendable () async throws -> MitateAPI
    var api: MitateAPI?
    /// 作り直した回数。古い接続で失敗した呼び出しが、ほかの呼び出しが作り直した接続を捨てないようにする
    var generation = 0
    init(connect: @escaping @Sendable () async throws -> MitateAPI) { self.connect = connect }

    func get() async throws -> (api: MitateAPI, generation: Int) {
      if let api { return (api, generation) }
      let made = try await connect()
      api = made
      generation += 1
      return (made, generation)
    }

    func reconnect(after stale: Int) async throws -> MitateAPI {
      if stale == generation { api = nil }
      return try await get().api
    }
  }

  /// 1 行の要求に答える。通知（id が無いもの）には何も返さない。
  public func handle(_ line: Data) async -> Data? {
    let message: JSONValue
    do {
      message = try JSONDecoder().decode(JSONValue.self, from: line)
    } catch {
      return Self.encode(["jsonrpc": .string("2.0"), "id": .null, "error": Self.rpcError(-32700, "JSON として読めない: \(error)")])
    }
    guard let method = message["method"]?.string else {
      return Self.encode(["jsonrpc": .string("2.0"), "id": message["id"] ?? .null, "error": Self.rpcError(-32600, "method が無い")])
    }
    guard let id = message["id"] else { return nil }
    let params = message["params"] ?? .object([:])
    do {
      let result = try await dispatch(method, params)
      return Self.encode(["jsonrpc": .string("2.0"), "id": id, "result": result])
    } catch let error as RPCError {
      return Self.encode(["jsonrpc": .string("2.0"), "id": id, "error": Self.rpcError(error.code, error.message)])
    } catch {
      return Self.encode(["jsonrpc": .string("2.0"), "id": id, "error": Self.rpcError(-32603, "\(error)")])
    }
  }

  struct RPCError: Error {
    let code: Int
    let message: String
  }

  private func dispatch(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    switch method {
    case "initialize":
      return .object([
        "protocolVersion": params["protocolVersion"] ?? .string("2025-06-18"),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object(["name": .string("mitate"), "version": .string("0.1.0")]),
        "instructions": .string(Self.instructions),
      ])
    case "ping":
      return .object([:])
    case "tools/list":
      return .object(["tools": .array(Self.tools)])
    case "tools/call":
      guard let name = params["name"]?.string else { throw RPCError(code: -32602, message: "name が無い") }
      guard Self.toolNames.contains(name) else { throw RPCError(code: -32602, message: "ツール \(name) は無い") }
      return await call(name, params["arguments"] ?? .object([:]))
    default:
      throw RPCError(code: -32601, message: "\(method) は無い")
    }
  }

  // MARK: - ツール

  static let instructions = """
    Mitate は、利用者が毎日見ているデザインサイト（Pinterest、Detail、Design Spells、Recent、Collect UI、X など）を横断して引く、利用者の Mac の中の索引。\
    UI の参考を探すときは search を使い、返った番号付きのコンタクトシートで候補を見て、気になる番号の id を view で拡大する。\
    利用者が手元で選んだ参考は selection で読める。
    """

  static let defaultLimit = 12
  /// limit の上限。コンタクトシートに並べる件数の上限も兼ねる
  static let maxLimit = 40

  static let toolNames = Set(tools.compactMap { $0["name"]?.string })

  static let tools: [JSONValue] = {
    func prop(_ type: String, _ description: String, extra: [String: JSONValue] = [:]) -> JSONValue {
      .object(["type": .string(type), "description": .string(description)].merging(extra) { a, _ in a })
    }
    let sources = prop("array", "絞り込むサイトの id（sources ツールで分かる。例：pinterest、designspells）。省くと全サイト", extra: ["items": .object(["type": .string("string")])])
    let kind = prop("string", "種類で絞る。image は静止画、video は動く部品や操作の録画、text は記事・講義・ツールの説明", extra: ["enum": .array(["image", "video", "text"].map(JSONValue.string))])
    let limit = prop("integer", "返す件数。既定 \(defaultLimit)、最大 \(maxLimit)", extra: ["minimum": .int(1), "maximum": .int(maxLimit)])
    func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
      .object([
        "name": .string(name),
        "description": .string(description),
        "inputSchema": .object([
          "type": .string("object"),
          "properties": .object(properties),
          "required": .array(required.map(JSONValue.string)),
          "additionalProperties": .bool(false),
        ]),
      ])
    }
    return [
      tool("search", """
        利用者のデザインの参考の索引を、検索語で引く。全文検索と画像の埋め込みの両方で引くので、日本語でも英語でも、画像に文字が無くても当たる（例：「トグル」「dark dashboard」「料金表」）。\
        番号付きのコンタクトシート 1 枚（画像）と、番号ごとのタイトル・サイト・url・origin・kind・主要色・id の一覧を返す。\
        live が true なら、Pinterest や X など検索を持つサイトにも問い合わせ、届いた結果も同じ順位に混ぜて返す（数秒かかる。サイトへの問い合わせには上限があり、同じ検索語は 10 分間使い回す）。\
        手元だけで速く引きたいときは live を false にする。
        """, [
        "query": prop("string", "検索語。部品名、画面の種類、雰囲気、色など"),
        "sources": sources, "kind": kind, "limit": limit,
        "live": prop("boolean", "検索を持つサイトにも問い合わせるか。既定 true"),
      ], required: ["query"]),
      tool("similar", """
        見た目が近い参考を引く。id（search などが返した Shot の id）か image_path（手元の画像ファイル。Storybook の部品のスクリーンショットなど）のどちらか一方を渡す。\
        search と同じく、番号付きのコンタクトシートと一覧を返す。自分自身とほぼ同じ画像は除く。
        """, [
        "id": prop("string", "近いものを探す元の Shot の id"),
        "image_path": prop("string", "近いものを探す元の画像ファイルの絶対パス（png・jpeg・webp・heic など）"),
        "sources": sources, "kind": kind, "limit": limit,
      ]),
      tool("view", """
        1 件の Shot を詳しく見る。画像は長辺 1568px までの原寸、動画は等間隔に並べたフレーム列と各フレームの時刻、文章は保存してある本文を返す。どれも全項目（url、origin、作者、タグ、主要色など）を text で添える。
        """, ["id": prop("string", "Shot の id（search・similar・selection が返したもの）")], required: ["id"]),
      tool("selection", """
        利用者がビューワーで選んだ参考と、それぞれに付けたメモを、選んだ順に返す。番号付きのコンタクトシートを添える。利用者が「選んだもの」「これを参考に」と言ったときに使う。
        """, [:]),
      tool("sources", """
        索引に入っているサイトの一覧。サイトごとの id、件数、ログイン状態、取得状態を返す。search や similar の sources に渡す id を知るときに使う。
        """, [:]),
    ]
  }()

  enum Content {
    case text(String)
    case jpeg(Data)

    var json: JSONValue {
      switch self {
      case let .text(t): .object(["type": .string("text"), "text": .string(t)])
      case let .jpeg(d): .object(["type": .string("image"), "data": .string(d.base64EncodedString()), "mimeType": .string("image/jpeg")])
      }
    }
  }

  struct ToolError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  private func call(_ name: String, _ args: JSONValue) async -> JSONValue {
    do {
      let content = try await run(name, args)
      // 画像は文章より前に置く。
      let ordered = content.filter { if case .jpeg = $0 { true } else { false } } + content.filter { if case .text = $0 { true } else { false } }
      return .object(["content": .array(ordered.map(\.json)), "isError": .bool(false)])
    } catch {
      return .object(["content": .array([Content.text("\(error)").json]), "isError": .bool(true)])
    }
  }

  private func run(_ name: String, _ args: JSONValue) async throws -> [Content] {
    guard case .object = args else { throw ToolError(message: "arguments はオブジェクト") }
    let (api, generation) = try await connection.get()
    do {
      return try await perform(name, args, api)
    } catch where Self.lostApp(error) {
      log("mcp: アプリにつながらない（\((error as? URLError)?.localizedDescription ?? "\(error)")）。server.json を読み直してつなぎ直す")
      return try await perform(name, args, try await connection.reconnect(after: generation))
    }
  }

  /// アプリが終わったか、起動し直して port か token が変わった。
  static func lostApp(_ error: Error) -> Bool {
    if let error = error as? URLError {
      return [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet].contains(error.code)
    }
    return (error as? ClientError)?.status == 401
  }

  private func perform(_ name: String, _ args: JSONValue, _ api: MitateAPI) async throws -> [Content] {
    switch name {
    case "search":
      guard let query = args["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { throw ToolError(message: "query が無い") }
      let live = try optionalBool(args, "live") ?? true
      let limit = try limitArg(args)
      let (shots, errors) = try await search(api, query, sources: try sourcesArg(args), kinds: try kindArg(args), limit: limit, live: live)
      let notes = errors.map { "\($0.source) には問い合わせられなかった: \($0.message)" }
      return try await listing(api, shots, empty: "「\(query)」に当たる Shot は無かった", notes: notes)
    case "similar":
      let id = args["id"]?.string
      let path = args["image_path"]?.string
      guard (id == nil) != (path == nil) else { throw ToolError(message: "id と image_path のどちらか一方だけを渡す") }
      let shots: [ShotView]
      if let id {
        shots = try await api.similar(id: id, sources: try sourcesArg(args), kinds: try kindArg(args), limit: try limitArg(args))
      } else {
        let (data, type) = try Self.readImage(path!)
        shots = try await api.similar(image: data, mimeType: type, sources: try sourcesArg(args), kinds: try kindArg(args), limit: try limitArg(args))
      }
      return try await listing(api, shots, empty: "近い Shot は無かった", notes: [])
    case "view":
      guard let id = args["id"]?.string, !id.isEmpty else { throw ToolError(message: "id が無い") }
      return try await view(api, id)
    case "selection":
      let shots = try await api.selection()
      return try await listing(api, shots, empty: "利用者はまだ何も選んでいない", notes: [])
    case "sources":
      return [.text(Self.describe(try await api.sources()))]
    default:
      throw ToolError(message: "ツール \(name) は無い")
    }
  }

  /// live のときは done まで受けてから live なしで引き直し、引き直した順位と各サイトの結果を RRF でまとめる。
  func search(_ api: MitateAPI, _ query: String, sources: [String]?, kinds: [ShotKind]?, limit: Int, live: Bool) async throws -> ([ShotView], [(source: String, message: String)]) {
    var lists: [[ShotView]] = []
    var errors: [(String, String)] = []
    if live {
      for try await event in api.search(query, sources: sources, kinds: kinds, limit: limit, live: true) {
        switch event {
        case let .live(_, shots): lists.append(shots)
        case let .error(source, message): errors.append((source, message))
        case .local, .done: break
        }
      }
    }
    var local: [ShotView] = []
    for try await event in api.search(query, sources: sources, kinds: kinds, limit: limit, live: false) {
      if case let .local(shots) = event { local = shots }
    }
    var byId: [String: ShotView] = [:]
    for shot in lists.joined() { byId[shot.id] = shot }
    for shot in local { byId[shot.id] = shot }
    let order = Ranking.fuse([local.map(\.id)] + lists.map { $0.map(\.id) })
    return (order.prefix(limit).compactMap { byId[$0] }, errors)
  }

  /// コンタクトシートには先頭の `maxLimit` 件だけを並べ、一覧には全件を載せる。
  private func listing(_ api: MitateAPI, _ shots: [ShotView], empty: String, notes: [String]) async throws -> [Content] {
    guard !shots.isEmpty else { return [.text(([empty] + notes).joined(separator: "\n"))] }
    let names = Dictionary(try await api.sources().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let onSheet = shots.prefix(Self.maxLimit)
    let sheet = try await api.sheet(ids: onSheet.map(\.id))
    let head = onSheet.count == shots.count
      ? "\(shots.count) 件。番号はコンタクトシートの番号。"
      : "\(shots.count) 件。コンタクトシートには先頭 \(onSheet.count) 件を並べた（番号はシートの番号と同じ）。\(onSheet.count + 1) 件目からは一覧だけにある。"
    var lines = [head + "詳しく見るときは id を view に渡す。"]
    for (i, shot) in shots.enumerated() {
      lines.append("")
      lines += Self.summary(shot, number: i + 1, siteName: names[shot.source])
    }
    if !notes.isEmpty { lines += [""] + notes }
    return [.jpeg(sheet), .text(lines.joined(separator: "\n"))]
  }

  static func summary(_ shot: ShotView, number: Int, siteName: String?) -> [String] {
    var lines = ["\(number). \(shot.title.map(oneLine) ?? "（タイトルなし）")"]
    lines.append("   サイト: \(siteName.map { "\($0)（\(shot.source)）" } ?? shot.source)　kind: \(shot.kind.rawValue)\(shot.colors.isEmpty ? "" : "　主要色: \(shot.colors.joined(separator: " "))")")
    lines.append("   url: \(shot.url)")
    if let origin = shot.origin { lines.append("   origin: \(origin)") }
    if shot.duplicates > 1 { lines.append("   ほぼ同じ画像 \(shot.duplicates) 件を 1 件にまとめた") }
    if shot.selected { lines.append("   利用者が選んだもの\(shot.note.map { "。メモ: \($0)" } ?? "")") }
    lines.append("   id: \(shot.id)")
    return lines
  }

  private func view(_ api: MitateAPI, _ id: String) async throws -> [Content] {
    let shot = try await api.shot(id)
    let fields = Self.fields(shot)
    switch shot.kind {
    case .image:
      return [.jpeg(try await api.view(id: id)), .text(fields)]
    case .video:
      let frames = try await api.frames(id: id, count: 8)
      let isHLS = shot.media.flatMap { URL(string: $0.src) }.map(Thumbnailer.isHLS) ?? false
      let head = isHLS
        ? "HLS の動画なのでフレームを取れなかった。poster 1 枚を返す。動きを確かめるには url を開く。"
        : "動画を等間隔に \(frames.times.count) 枚並べたフレーム列。各フレームの時刻: " + frames.times.enumerated().map { "\($0.offset + 1): \(String(format: "%.1f", Double($0.element) / 1000)) 秒" }.joined(separator: "、")
      return [.jpeg(frames.jpeg), .text(head + "\n\n" + fields)]
    case .text:
      let body = shot.text ?? ""
      return [.text("保存してある本文（サイトから取った冒頭か説明文で、全文とは限らない。全文は url で読む: \(shot.url)）\n\n\(body)\n\n\(fields)")]
    }
  }

  /// 改行や連続する空白を 1 つの空白にする。一覧の 1 行に収めるため。
  public static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Shot の全項目。
  static func fields(_ shot: ShotView) -> String {
    var lines = ["id: \(shot.id)", "source: \(shot.source)", "kind: \(shot.kind.rawValue)", "url: \(shot.url)"]
    if let origin = shot.origin { lines.append("origin: \(origin)") }
    lines.append("title: \(shot.title ?? "（なし）")")
    if let author = shot.author { lines.append("author: \(author)") }
    if let date = shot.publishedAt { lines.append("publishedAt: \(date)") }
    lines.append("tags: \(shot.tags.isEmpty ? "（なし）" : shot.tags.joined(separator: ", "))")
    if !shot.colors.isEmpty { lines.append("colors: \(shot.colors.joined(separator: " "))") }
    if let aspect = shot.aspect { lines.append(String(format: "aspect: %.3f", aspect)) }
    if let media = shot.media {
      lines.append("media.src: \(media.src)")
      if let poster = media.poster { lines.append("media.poster: \(poster)") }
      if let w = media.width, let h = media.height { lines.append("media.size: \(Int(w))×\(Int(h))") }
    }
    lines.append("duplicates: \(shot.duplicates)")
    lines.append("selected: \(shot.selected)")
    if let note = shot.note { lines.append("note: \(note)") }
    return lines.joined(separator: "\n")
  }

  public static func describe(_ sources: [SourceStatus]) -> String {
    var lines = ["\(sources.count) サイト"]
    for s in sources {
      let login = switch s.login {
      case .none: "ログイン不要"
      case .signedIn: "ログイン済み"
      case .signedOut: "未ログイン"
      case .unknown: "ログイン状態は未確認"
      }
      let sync = switch s.sync {
      case .idle: "待機中"
      case let .syncing(done): "取得中（\(done) 件）"
      case let .failed(message): "失敗: \(message)"
      }
      let abilities = [s.canList ? "全件を写す" : nil, s.canSearch ? "検索に問い合わせる" : nil].compactMap { $0 }.joined(separator: "・")
      lines.append("- \(s.name)（id: \(s.id)）: \(s.count) 件、\(login)、\(sync)、\(abilities)\(s.lastSyncedAt.map { "、最終取得 \($0)" } ?? "")")
    }
    return lines.joined(separator: "\n")
  }

  static func readImage(_ path: String) throws -> (Data, String) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType else {
      throw ToolError(message: "\(path) は画像のファイルではない（拡張子から画像の種類が分からない）")
    }
    do {
      return (try Data(contentsOf: url), mime)
    } catch {
      throw ToolError(message: "\(path) を読めない: \(error.localizedDescription)")
    }
  }

  // MARK: - 引数

  private func sourcesArg(_ args: JSONValue) throws -> [String]? {
    guard let value = args["sources"], value != .null else { return nil }
    guard let items = value.array?.compactMap(\.string), items.count == value.array?.count else { throw ToolError(message: "sources は文字列の配列") }
    return items.isEmpty ? nil : items
  }

  private func kindArg(_ args: JSONValue) throws -> [ShotKind]? {
    guard let value = args["kind"], value != .null else { return nil }
    guard let kind = value.string.flatMap(ShotKind.init(rawValue:)) else { throw ToolError(message: "kind は image・video・text のどれか") }
    return [kind]
  }

  private func limitArg(_ args: JSONValue) throws -> Int {
    guard let value = args["limit"], value != .null else { return Self.defaultLimit }
    guard let n = value.int, (1 ... Self.maxLimit).contains(n) else { throw ToolError(message: "limit は 1〜\(Self.maxLimit) の整数") }
    return n
  }

  private func optionalBool(_ args: JSONValue, _ name: String) throws -> Bool? {
    guard let value = args[name], value != .null else { return nil }
    guard let b = value.bool else { throw ToolError(message: "\(name) は真偽値") }
    return b
  }

  private static func rpcError(_ code: Int, _ message: String) -> JSONValue {
    .object(["code": .int(code), "message": .string(message)])
  }

  private static func encode(_ object: [String: JSONValue]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    // JSONValue の encode は失敗しない（非有限の数は JSON から読めないので入らない）。
    return try! encoder.encode(JSONValue.object(object))
  }
}
