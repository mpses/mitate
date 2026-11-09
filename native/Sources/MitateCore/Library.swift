import Foundation
import SQLite3

public struct LibraryError: Error, CustomStringConvertible {
  public let message: String
  public var description: String { message }
}

public enum Via: String, Sendable {
  case list, search
}

public struct SourceProgress: Sendable, Equatable {
  public var cursor: String?
  public var complete: Bool
  public var lastSyncedAt: String?
  public var lastError: String?
}

/// サムネイルと埋め込みの計算に要る 1 件分。
public struct MediaJob: Sendable {
  public let id: String
  public let source: String
  public let kind: ShotKind
  public let media: ShotMedia?
  public let title: String?
  public let text: String?
  public let thumb: String?
  public let thumbAttempts: Int
}

/// 手元の 1 件と、並べ替えに要る値。
public struct LibraryRow: Sendable {
  public var view: ShotView
  public var via: Via
}

public enum Timestamp {
  public static func string(_ date: Date = Date()) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
  }

  public static func parse(_ text: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
  }

  /// 日付順に並べられるよう、読める日時は UTC の同じ書式に揃える。
  static func normalize(_ text: String?) -> String? {
    guard let text else { return nil }
    return parse(text).map { string($0) } ?? text
  }
}

/// `library.sqlite`。接続は 1 本で、呼び出しをロックで直列にする。
public final class Library: @unchecked Sendable {
  private let db: OpaquePointer
  private let lock = NSLock()

  public init(url: URL) throws {
    var handle: OpaquePointer?
    let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
    guard rc == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
      sqlite3_close(handle)
      throw LibraryError(message: "\(url.path) を開けない: \(message)")
    }
    db = handle
    sqlite3_busy_timeout(db, 5000)
    try exec(Self.schema)
  }

  deinit {
    sqlite3_close(db)
  }

  static let schema = """
    pragma journal_mode = wal;
    pragma synchronous = normal;
    create table if not exists shots (
      id text primary key, source text not null, url text not null, origin text,
      kind text not null, title text, text text, tags text not null, author text,
      published_at text, media text, via text not null,
      first_seen_at text not null, last_seen_at text not null,
      thumb text, aspect real, colors text, thumb_error text, thumb_attempts integer not null default 0
    );
    create index if not exists shots_source on shots(source);
    create virtual table if not exists shots_fts using fts5(title, text, tags, author, content='shots', content_rowid='rowid', tokenize='trigram');
    create trigger if not exists shots_ai after insert on shots begin
      insert into shots_fts(rowid, title, text, tags, author) values (new.rowid, new.title, new.text, new.tags, new.author);
    end;
    create trigger if not exists shots_ad after delete on shots begin
      insert into shots_fts(shots_fts, rowid, title, text, tags, author) values ('delete', old.rowid, old.title, old.text, old.tags, old.author);
    end;
    create trigger if not exists shots_au after update of title, text, tags, author on shots begin
      insert into shots_fts(shots_fts, rowid, title, text, tags, author) values ('delete', old.rowid, old.title, old.text, old.tags, old.author);
      insert into shots_fts(rowid, title, text, tags, author) values (new.rowid, new.title, new.text, new.tags, new.author);
    end;
    create table if not exists vectors (id text primary key, model text not null, data blob not null);
    create table if not exists marks (id text primary key, selected integer not null, note text, selected_at text);
    create table if not exists source_state (id text primary key, cursor text, complete integer not null default 0, last_synced_at text, last_error text);
    create table if not exists live_queries (source text not null, query text not null, fetched_at text not null, ids text not null, primary key (source, query));
    """

  // MARK: - Shot

  /// id で upsert する。`first_seen_at` は保ち、`list` で取ったことのあるものは `via` を `list` のまま残す。
  /// `progress` を渡すと、同じトランザクションでカーソルを保存する（途中で落ちても次はそのカーソルから再開できる）。
  /// 戻り値は、手元に無かった id。
  @discardableResult
  public func save(_ shots: [Shot], via: Via, progress: (source: String, cursor: String?, complete: Bool)? = nil, now: Date = Date()) throws -> Set<String> {
    try locked {
      try transaction {
        let at = Timestamp.string(now)
        let exists = try Statement(db, "select 1 from shots where id = ?")
        let upsert = try Statement(db, """
          insert into shots (id, source, url, origin, kind, title, text, tags, author, published_at, media, via, first_seen_at, last_seen_at)
          values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          on conflict(id) do update set
            source = excluded.source, url = excluded.url, origin = excluded.origin, kind = excluded.kind,
            title = excluded.title, text = excluded.text, tags = excluded.tags, author = excluded.author,
            published_at = coalesce(excluded.published_at, shots.published_at), media = excluded.media,
            via = case when shots.via = 'list' then 'list' else excluded.via end,
            last_seen_at = excluded.last_seen_at
          """)
        var fresh = Set<String>()
        for shot in shots {
          try exists.bind([shot.id])
          if try !exists.step() { fresh.insert(shot.id) }
          try upsert.bind([
            shot.id, shot.source, shot.url, shot.origin, shot.kind.rawValue, shot.title, shot.text,
            try json(shot.tags), shot.author, Timestamp.normalize(shot.publishedAt), try shot.media.map(json),
            via.rawValue, at, at,
          ])
          try upsert.run()
        }
        if let progress {
          try run("""
            insert into source_state (id, cursor, complete) values (?, ?, ?)
            on conflict(id) do update set cursor = excluded.cursor, complete = excluded.complete
            """, [progress.source, progress.cursor, progress.complete])
        }
        return fresh
      }
    }
  }

  static let viewColumns = "s.id, s.source, s.url, s.origin, s.kind, s.title, s.text, s.tags, s.author, s.published_at, s.media, s.thumb, s.aspect, s.colors, m.selected, m.note, s.via"

  /// ids の順に返す。手元に無い id は飛ばす。
  public func rows(_ ids: [String]) throws -> [LibraryRow] {
    guard !ids.isEmpty else { return [] }
    return try locked {
      var found: [String: LibraryRow] = [:]
      for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0 ..< min($0 + 500, ids.count)]) }) {
        let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
        let stmt = try Statement(db, "select \(Self.viewColumns) from shots s left join marks m on m.id = s.id where s.id in (\(marks))")
        try stmt.bind(chunk)
        while try stmt.step() {
          let row = try readRow(stmt)
          found[row.view.id] = row
        }
      }
      return ids.compactMap { found[$0] }
    }
  }

  public func views(_ ids: [String]) throws -> [ShotView] {
    try rows(ids).map(\.view)
  }

  public func view(_ id: String) throws -> ShotView? {
    try views([id]).first
  }

  private func readRow(_ s: Statement) throws -> LibraryRow {
    guard let kind = ShotKind(rawValue: s.text(4) ?? "") else { throw LibraryError(message: "shots.kind が不正: \(s.text(0) ?? "")") }
    let decoder = JSONDecoder()
    let view = ShotView(
      id: s.text(0) ?? "",
      source: s.text(1) ?? "",
      url: s.text(2) ?? "",
      origin: s.text(3),
      kind: kind,
      title: s.text(5),
      text: s.text(6),
      tags: try decoder.decode([String].self, from: Data((s.text(7) ?? "[]").utf8)),
      author: s.text(8),
      publishedAt: s.text(9),
      thumb: s.text(11).map { "/media/\($0).jpg" },
      media: try s.text(10).map { try decoder.decode(ShotMedia.self, from: Data($0.utf8)) },
      aspect: s.double(12),
      colors: try s.text(13).map { try decoder.decode([String].self, from: Data($0.utf8)) } ?? [],
      duplicates: 1,
      selected: s.int(14) == 1,
      note: s.text(15)
    )
    guard let via = Via(rawValue: s.text(16) ?? "") else { throw LibraryError(message: "shots.via が不正: \(view.id)") }
    return LibraryRow(view: view, via: via)
  }

  /// `source` のサイト内の id が手元にあるかを、渡した順に返す。
  public func known(source: String, ids: [String]) throws -> [Bool] {
    let full = ids.map { "\(source):\($0)" }
    var present = Set<String>()
    try locked {
      for chunk in stride(from: 0, to: full.count, by: 500).map({ Array(full[$0 ..< min($0 + 500, full.count)]) }) {
        let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
        try query("select id from shots where id in (\(marks))", chunk) { present.insert($0.text(0) ?? "") }
      }
    }
    return full.map(present.contains)
  }

  public func counts() throws -> [String: Int] {
    try locked {
      var out: [String: Int] = [:]
      try query("select source, count(*) from shots group by source", []) { out[$0.text(0) ?? ""] = $0.int(1) ?? 0 }
      return out
    }
  }

  // MARK: - 検索

  /// 検索語を空白で区切り、すべてを含むものを返す。3 文字以上の語は FTS（bm25 順）、それ未満は like で引く。
  public func search(_ query: String, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int) throws -> [String] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return [] }
    let long = terms.filter { $0.unicodeScalars.count >= 3 }
    let short = terms.filter { $0.unicodeScalars.count < 3 }
    var conditions: [String] = []
    var args: [Any?] = []
    if !long.isEmpty {
      conditions.append("shots_fts match ?")
      args.append(long.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " "))
    }
    for term in short {
      conditions.append("(s.title like ? escape '\\' or s.text like ? escape '\\' or s.tags like ? escape '\\' or s.author like ? escape '\\')")
      let pattern = "%" + term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
      args += Array(repeating: pattern, count: 4)
    }
    for (clause, values) in [Self.sourceFilter(sources), Self.kindFilter(kinds)] {
      if let clause { conditions.append(clause) }
      args += values
    }
    args.append(limit)
    let sql = long.isEmpty
      ? "select s.id from shots s where \(conditions.joined(separator: " and ")) order by coalesce(s.published_at, s.first_seen_at) desc limit ?"
      : "select s.id from shots_fts join shots s on s.rowid = shots_fts.rowid where \(conditions.joined(separator: " and ")) order by bm25(shots_fts, 4.0, 1.0, 2.0, 1.0) limit ?"
    return try locked {
      var ids: [String] = []
      try self.query(sql, args) { ids.append($0.text(0) ?? "") }
      return ids
    }
  }

  /// 検索語が無いときの壁。サイトごとに新しい順に並べ、サイトを 1 件ずつ順に回す。文章は検索の重みと同じく半分の頻度で出す。
  public func browse(sources: Set<String>?, kinds: Set<ShotKind>?, offset: Int, limit: Int) throws -> [String] {
    let filters = [Self.sourceFilter(sources), Self.kindFilter(kinds)]
    let clauses = filters.compactMap(\.0)
    let args = filters.flatMap(\.1)
    let sql = """
      select id from (
        select s.id, s.kind, coalesce(s.published_at, s.first_seen_at) as d,
          row_number() over (partition by s.source order by coalesce(s.published_at, s.first_seen_at) desc, s.id) as rn
        from shots s \(clauses.isEmpty ? "" : "where " + clauses.joined(separator: " and "))
      ) order by rn * (case kind when 'text' then 2 else 1 end), d desc, id limit ? offset ?
      """
    return try locked {
      var ids: [String] = []
      try query(sql, args + [limit, offset]) { ids.append($0.text(0) ?? "") }
      return ids
    }
  }

  static func sourceFilter(_ sources: Set<String>?) -> (String?, [Any?]) {
    guard let sources else { return (nil, []) }
    guard !sources.isEmpty else { return ("0", []) }
    return ("s.source in (\(Array(repeating: "?", count: sources.count).joined(separator: ",")))", sources.sorted())
  }

  static func kindFilter(_ kinds: Set<ShotKind>?) -> (String?, [Any?]) {
    guard let kinds else { return (nil, []) }
    guard !kinds.isEmpty else { return ("0", []) }
    return ("s.kind in (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))", kinds.map(\.rawValue).sorted())
  }

  // MARK: - サムネイル

  public func mediaJob(_ id: String) throws -> MediaJob? {
    try locked {
      var job: MediaJob?
      try query("select id, source, kind, media, title, text, thumb, thumb_attempts from shots where id = ?", [id]) { s in
        guard let kind = ShotKind(rawValue: s.text(2) ?? "") else { throw LibraryError(message: "shots.kind が不正: \(id)") }
        job = MediaJob(
          id: s.text(0) ?? "",
          source: s.text(1) ?? "",
          kind: kind,
          media: try s.text(3).map { try JSONDecoder().decode(ShotMedia.self, from: Data($0.utf8)) },
          title: s.text(4),
          text: s.text(5),
          thumb: s.text(6),
          thumbAttempts: s.int(7) ?? 0
        )
      }
      return job
    }
  }

  /// サムネイルを取るべきもの。新しい順。
  public func pendingThumbs() throws -> [String] {
    try locked {
      var ids: [String] = []
      try query("""
        select id from shots where thumb is null and thumb_attempts < 3 and (kind != 'text' or media is not null)
        order by coalesce(published_at, first_seen_at) desc
        """, []) { ids.append($0.text(0) ?? "") }
      return ids
    }
  }

  /// サムネイルを取り終えたもののうち、`model` の埋め込みが無いもの。
  public func pendingEmbeds(model: String) throws -> [String] {
    try locked {
      var ids: [String] = []
      try query("""
        select s.id from shots s left join vectors v on v.id = s.id and v.model = ?
        where v.id is null and (s.thumb is not null or (s.kind = 'text' and (s.media is null or s.thumb_attempts >= 3)))
        order by coalesce(s.published_at, s.first_seen_at) desc
        """, [model]) { ids.append($0.text(0) ?? "") }
      return ids
    }
  }

  /// 画像から計算し直せるよう、文章から計算した埋め込みは捨てる。
  public func setThumb(_ id: String, key: String, aspect: Double, colors: [String]) throws {
    try locked {
      try transaction {
        try run("update shots set thumb = ?, aspect = ?, colors = ?, thumb_error = null where id = ?", [key, aspect, try json(colors), id])
        try run("delete from vectors where id = ?", [id])
      }
    }
  }

  public func thumbFailed(_ id: String, error: String) throws {
    try locked { try run("update shots set thumb_error = ?, thumb_attempts = thumb_attempts + 1 where id = ?", [error, id]) }
  }

  // MARK: - 埋め込み

  /// 手元の Shot に対応する `model` の埋め込み。
  public func vectors(model: String) throws -> [(id: String, kind: ShotKind, vector: [Float])] {
    try locked {
      var out: [(String, ShotKind, [Float])] = []
      try query("select v.id, s.kind, v.data from vectors v join shots s on s.id = v.id where v.model = ?", [model]) { s in
        let id = s.text(0) ?? ""
        guard let kind = ShotKind(rawValue: s.text(1) ?? "") else { throw LibraryError(message: "shots.kind が不正: \(id)") }
        let data = s.blob(2)
        guard data.count % MemoryLayout<Float>.size == 0 else { throw LibraryError(message: "vectors.data の長さが Float の倍数ではない: \(id)") }
        let floats = [Float](unsafeUninitializedCapacity: data.count / MemoryLayout<Float>.size) { buffer, count in
          count = data.copyBytes(to: buffer) / MemoryLayout<Float>.size
        }
        out.append((id, kind, floats))
      }
      return out
    }
  }

  public func setVector(_ id: String, model: String, vector: [Float]) throws {
    let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    try locked { try run("insert or replace into vectors (id, model, data) values (?, ?, ?)", [id, model, data]) }
  }

  // MARK: - 選択

  public func setMark(_ id: String, selected: Bool, note: String?, now: Date = Date()) throws {
    try locked {
      try run("""
        insert into marks (id, selected, note, selected_at) values (?1, ?2, ?3, case when ?2 = 1 then ?4 end)
        on conflict(id) do update set selected = ?2, note = ?3,
          selected_at = case when ?2 = 1 then coalesce(marks.selected_at, ?4) end
        """, [id, selected, note, Timestamp.string(now)])
    }
  }

  /// 選んだ順。
  public func selection() throws -> [String] {
    try locked {
      var ids: [String] = []
      try query("select m.id from marks m join shots s on s.id = m.id where m.selected = 1 order by m.selected_at, m.id", []) { ids.append($0.text(0) ?? "") }
      return ids
    }
  }

  public func clearSelection() throws {
    try locked { try run("update marks set selected = 0, selected_at = null where selected = 1", []) }
  }

  // MARK: - サイトの取得状態

  public func progress(_ source: String) throws -> SourceProgress {
    try allProgress()[source] ?? SourceProgress(cursor: nil, complete: false, lastSyncedAt: nil, lastError: nil)
  }

  public func allProgress() throws -> [String: SourceProgress] {
    try locked {
      var out: [String: SourceProgress] = [:]
      try query("select id, cursor, complete, last_synced_at, last_error from source_state", []) {
        out[$0.text(0) ?? ""] = SourceProgress(cursor: $0.text(1), complete: $0.int(2) == 1, lastSyncedAt: $0.text(3), lastError: $0.text(4))
      }
      return out
    }
  }

  public func syncFinished(_ source: String, now: Date = Date()) throws {
    try locked {
      try run("""
        insert into source_state (id, last_synced_at) values (?1, ?2)
        on conflict(id) do update set last_synced_at = ?2, last_error = null
        """, [source, Timestamp.string(now)])
    }
  }

  public func syncFailed(_ source: String, message: String) throws {
    try locked {
      try run("insert into source_state (id, last_error) values (?1, ?2) on conflict(id) do update set last_error = ?2", [source, message])
    }
  }

  // MARK: - live 検索の使い回し

  public func liveQuery(source: String, query text: String) throws -> (fetchedAt: Date, ids: [String])? {
    try locked {
      var out: (Date, [String])?
      try query("select fetched_at, ids from live_queries where source = ? and query = ?", [source, text]) { s in
        guard let at = s.text(0).flatMap(Timestamp.parse) else { throw LibraryError(message: "live_queries.fetched_at が不正: \(source) \(text)") }
        out = (at, try JSONDecoder().decode([String].self, from: Data((s.text(1) ?? "[]").utf8)))
      }
      return out
    }
  }

  public func setLiveQuery(source: String, query: String, ids: [String], now: Date = Date()) throws {
    try locked {
      try run("insert or replace into live_queries (source, query, fetched_at, ids) values (?, ?, ?, ?)", [source, query, Timestamp.string(now), try json(ids)])
    }
  }

  // MARK: - SQLite

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("begin immediate")
    do {
      let value = try body()
      try exec("commit")
      return value
    } catch {
      try? exec("rollback")
      throw error
    }
  }

  private func exec(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(message)
      throw LibraryError(message: "SQL が失敗: \(text)")
    }
  }

  private func run(_ sql: String, _ args: [Any?]) throws {
    let stmt = try Statement(db, sql)
    try stmt.bind(args)
    try stmt.run()
  }

  private func query(_ sql: String, _ args: [Any?], _ row: (Statement) throws -> Void) throws {
    let stmt = try Statement(db, sql)
    try stmt.bind(args)
    while try stmt.step() { try row(stmt) }
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Statement {
  private let db: OpaquePointer
  private let stmt: OpaquePointer

  init(_ db: OpaquePointer, _ sql: String) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw LibraryError(message: "SQL を準備できない: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(120))")
    }
    self.db = db
    self.stmt = stmt
  }

  deinit {
    sqlite3_finalize(stmt)
  }

  func bind(_ values: [Any?]) throws {
    sqlite3_reset(stmt)
    sqlite3_clear_bindings(stmt)
    for (offset, value) in values.enumerated() {
      let i = Int32(offset + 1)
      let rc: Int32
      switch value {
      case nil: rc = sqlite3_bind_null(stmt, i)
      case let v as String: rc = sqlite3_bind_text(stmt, i, v, -1, transient)
      case let v as Bool: rc = sqlite3_bind_int64(stmt, i, v ? 1 : 0)
      case let v as Int: rc = sqlite3_bind_int64(stmt, i, Int64(v))
      case let v as Double: rc = sqlite3_bind_double(stmt, i, v)
      case let v as Data: rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), transient) }
      case let v?: throw LibraryError(message: "bind できない型: \(type(of: v))")
      }
      guard rc == SQLITE_OK else { throw LibraryError(message: "bind に失敗: \(String(cString: sqlite3_errmsg(db)))") }
    }
  }

  /// 行があれば true。
  func step() throws -> Bool {
    switch sqlite3_step(stmt) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw LibraryError(message: "SQL が失敗: \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  func run() throws {
    while try step() {}
  }

  func text(_ i: Int32) -> String? {
    sqlite3_column_text(stmt, i).map { String(cString: $0) }
  }

  func int(_ i: Int32) -> Int? {
    sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
  }

  func double(_ i: Int32) -> Double? {
    sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
  }

  func blob(_ i: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(stmt, i) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
  }
}
