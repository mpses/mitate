import Foundation

// HTTP で受け渡す形。ビューワー（web/src/api.ts）と MCP はこの形だけを前提にする。
// 形を変えたら `swift run Mitate fixtures ../web/src/fixtures` で fixture を書き直し、web の型検査で食い違いを検出する。

/// 壁に並べる 1 件。Shot に、表示に要る値と利用者の印を足したもの。
public struct ShotView: Codable, Hashable, Sendable {
  public var id: String
  public var source: String
  public var url: String
  public var origin: String?
  public var kind: ShotKind
  public var title: String?
  public var text: String?
  public var tags: [String]
  public var author: String?
  public var publishedAt: String?
  /// 手元のサムネイル。`/media/<key>.jpg`。まだ取得していなければ nil
  public var thumb: String?
  /// 元のメディア。動画の再生と原寸表示に使う
  public var media: ShotMedia?
  /// 幅 ÷ 高さ。分からなければ nil
  public var aspect: Double?
  /// 主要色。多い順に最大 5 色の `#rrggbb`
  public var colors: [String]
  /// ほぼ同じ画像として 1 枚にまとめた件数（自分を含む）
  public var duplicates: Int
  public var selected: Bool
  public var note: String?

  public init(id: String, source: String, url: String, origin: String?, kind: ShotKind, title: String?, text: String?, tags: [String], author: String?, publishedAt: String?, thumb: String?, media: ShotMedia?, aspect: Double?, colors: [String], duplicates: Int, selected: Bool, note: String?) {
    self.id = id
    self.source = source
    self.url = url
    self.origin = origin
    self.kind = kind
    self.title = title
    self.text = text
    self.tags = tags
    self.author = author
    self.publishedAt = publishedAt
    self.thumb = thumb
    self.media = media
    self.aspect = aspect
    self.colors = colors
    self.duplicates = duplicates
    self.selected = selected
    self.note = note
  }
}

public enum LoginState: String, Codable, Sendable {
  /// ログインの要らないサイト
  case none
  case signedIn
  case signedOut
  /// まだ確かめていない
  case unknown
}

public enum SyncState: Codable, Hashable, Sendable {
  case idle
  case syncing(done: Int)
  case failed(message: String)

  private enum CodingKeys: String, CodingKey { case state, done, message }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .idle: try c.encode("idle", forKey: .state)
    case let .syncing(done):
      try c.encode("syncing", forKey: .state)
      try c.encode(done, forKey: .done)
    case let .failed(message):
      try c.encode("failed", forKey: .state)
      try c.encode(message, forKey: .message)
    }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .state) {
    case "idle": self = .idle
    case "syncing": self = .syncing(done: try c.decode(Int.self, forKey: .done))
    case "failed": self = .failed(message: try c.decode(String.self, forKey: .message))
    case let other: throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "unknown sync state \(other)")
    }
  }
}

public struct SourceStatus: Codable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var home: String
  /// サイトの favicon。`/media/icon-<id>.png`
  public var icon: String?
  public var canList: Bool
  public var canSearch: Bool
  public var login: LoginState
  /// 手元に持っている件数
  public var count: Int
  public var sync: SyncState
  public var lastSyncedAt: String?

  public init(id: String, name: String, home: String, icon: String?, canList: Bool, canSearch: Bool, login: LoginState, count: Int, sync: SyncState, lastSyncedAt: String?) {
    self.id = id
    self.name = name
    self.home = home
    self.icon = icon
    self.canList = canList
    self.canSearch = canSearch
    self.login = login
    self.count = count
    self.sync = sync
    self.lastSyncedAt = lastSyncedAt
  }
}

/// `/api/search` は NDJSON で 1 行ずつこの形を流す。手元の結果を先に、サイトへ問い合わせた結果を届いた順に。
public enum SearchEvent: Codable, Hashable, Sendable {
  case local(shots: [ShotView])
  case live(source: String, shots: [ShotView])
  case error(source: String, message: String)
  case done

  private enum CodingKeys: String, CodingKey { case type, source, shots, message }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .local(shots):
      try c.encode("local", forKey: .type)
      try c.encode(shots, forKey: .shots)
    case let .live(source, shots):
      try c.encode("live", forKey: .type)
      try c.encode(source, forKey: .source)
      try c.encode(shots, forKey: .shots)
    case let .error(source, message):
      try c.encode("error", forKey: .type)
      try c.encode(source, forKey: .source)
      try c.encode(message, forKey: .message)
    case .done:
      try c.encode("done", forKey: .type)
    }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "local": self = .local(shots: try c.decode([ShotView].self, forKey: .shots))
    case "live": self = .live(source: try c.decode(String.self, forKey: .source), shots: try c.decode([ShotView].self, forKey: .shots))
    case "error": self = .error(source: try c.decode(String.self, forKey: .source), message: try c.decode(String.self, forKey: .message))
    case "done": self = .done
    case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown search event \(other)")
    }
  }
}

public struct ShotsResponse: Codable, Hashable, Sendable {
  public var shots: [ShotView]
  public init(shots: [ShotView]) { self.shots = shots }
}

public struct SourcesResponse: Codable, Hashable, Sendable {
  public var sources: [SourceStatus]
  public init(sources: [SourceStatus]) { self.sources = sources }
}

public struct SelectionUpdate: Codable, Hashable, Sendable {
  public var selected: Bool
  public var note: String?
}

/// 起動中のアプリが書く接続情報。`~/Library/Application Support/Mitate/server.json`（0600）
public struct ServerInfo: Codable, Hashable, Sendable {
  public var port: Int
  public var token: String
  public var pid: Int32
  public init(port: Int, token: String, pid: Int32) {
    self.port = port
    self.token = token
    self.pid = pid
  }
}
