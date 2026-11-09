import Foundation

/// live 検索の上限。利用者のアカウントを守るため、呼び出し元に関わらずエンジンが課す。
public enum RateLimit {
  /// 同じサイトへの問い合わせの間隔
  public static let spacing: TimeInterval = 4
  public static let window: TimeInterval = 60
  public static let perWindow = 6
  /// 同じ検索語の結果を、問い合わせずに使い回す時間
  public static let reuse: TimeInterval = 600

  /// 問い合わせてよければ nil、上限に達していればその理由。
  public static func refusal(history: [Date], now: Date, spacing: TimeInterval = spacing, window: TimeInterval = window, perWindow: Int = perWindow) -> String? {
    if let last = history.max(), now.timeIntervalSince(last) < spacing {
      return String(format: "問い合わせの間隔が %.0f 秒未満（%.1f 秒前に問い合わせた）", spacing, now.timeIntervalSince(last))
    }
    if history.filter({ now.timeIntervalSince($0) < window }).count >= perWindow {
      return "1 分あたり \(perWindow) 回の問い合わせの上限に達した"
    }
    return nil
  }

  /// 使い回しの鍵。大文字小文字と空白の違いは同じ検索語とみなす。
  public static func key(_ query: String) -> String {
    query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

/// サイトごとの live 検索の問い合わせの記録。
/// サイトの列で問い合わせを始める直前に `admit` を呼ぶので、列で待った時間は間隔に数えない。
public final class LiveLimiter: @unchecked Sendable {
  private let spacing: TimeInterval
  private let window: TimeInterval
  private let perWindow: Int
  private var history: [String: [Date]] = [:]
  private let lock = NSLock()

  public init(spacing: TimeInterval = RateLimit.spacing, window: TimeInterval = RateLimit.window, perWindow: Int = RateLimit.perWindow) {
    self.spacing = spacing
    self.window = window
    self.perWindow = perWindow
  }

  /// 上限の内なら問い合わせた時刻として記録し、上限に達していれば `LiveError` を投げる。
  public func admit(_ source: String, now: Date = Date()) throws {
    try lock.withLock {
      let recent = (history[source] ?? []).filter { now.timeIntervalSince($0) < window }
      history[source] = recent
      if let refusal = RateLimit.refusal(history: recent, now: now, spacing: spacing, window: window, perWindow: perWindow) {
        throw LiveError(message: refusal)
      }
      history[source] = recent + [now]
    }
  }
}

public struct LiveError: Error, CustomStringConvertible {
  public let message: String
  public var description: String { message }
}

/// サイトの差分取得と、live 検索の問い合わせ。差分取得は 1 サイトずつ行う。
/// 同じサイトへの呼び出しの直列化と間隔（pace）は SourceRunner が受け持つ。
public actor Syncer {
  private let library: Library
  private let runner: SourceRunner
  private let files: [String: SourceFile]
  private let pipeline: Pipeline
  private var login: [String: LoginState] = [:]
  private var state: [String: SyncState] = [:]
  private var waiting: [String] = []
  private var running: Set<String> = []
  private let limiter = LiveLimiter()

  /// 隠しタブはサイトごとに 140〜470MB を持つので、ビューワーと埋め込みに重なってもメモリが膨らまないよう 1 つずつ取る
  static let parallel = 1
  static let interval: TimeInterval = 6 * 3600

  public init(library: Library, runner: SourceRunner, files: [String: SourceFile], pipeline: Pipeline) throws {
    self.library = library
    self.runner = runner
    self.files = files
    self.pipeline = pipeline
    for (id, progress) in try library.allProgress() {
      if let error = progress.lastError { state[id] = .failed(message: error) }
    }
  }

  public func status(_ id: String) -> (login: LoginState, sync: SyncState) {
    let file = files[id]
    let login = file?.meta.loginURL == nil ? LoginState.none : (login[id] ?? .unknown)
    return (login, state[id] ?? .idle)
  }

  /// 起動時と 6 時間ごとに、`list` を持つ全サイトを取る。
  /// `search` だけを持つログインの要るサイトは、起動時にログイン状態だけを確かめる。
  public func schedule() {
    for (id, file) in files.sorted(by: { $0.key < $1.key }) where file.meta.loginURL != nil && !file.meta.canList {
      Task { await self.refreshLogin(id) }
    }
    Task {
      while true {
        self.request(nil)
        try await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
      }
    }
  }

  /// `source` が nil なら全サイト。取得中や順番待ちのサイトは重ねない。
  public func request(_ source: String?) {
    let ids = source.map { [$0] } ?? files.keys.sorted()
    for id in ids where files[id]?.meta.canList == true && !running.contains(id) && !waiting.contains(id) {
      waiting.append(id)
    }
    pump()
  }

  /// ログイン状態を確かめ直す。ログインできていて `list` を持てば取得を始める。
  public func refreshLogin(_ id: String) async {
    guard let file = files[id], file.meta.loginURL != nil else { return }
    do {
      let ok = try await runner.signedIn(file)
      login[id] = ok ? .signedIn : .signedOut
      if ok { request(id) }
    } catch {
      login[id] = .unknown
      state[id] = .failed(message: "ログイン状態を確かめられない: \(error)")
    }
  }

  private func pump() {
    while running.count < Self.parallel, !waiting.isEmpty {
      let id = waiting.removeFirst()
      running.insert(id)
      Task {
        await self.run(id)
        self.done(id)
      }
    }
  }

  private func done(_ id: String) {
    running.remove(id)
    pump()
  }

  private func run(_ id: String) async {
    guard let file = files[id] else { return }
    state[id] = .syncing(done: 0)
    do {
      if file.meta.loginURL != nil {
        let ok = try await runner.signedIn(file)
        login[id] = ok ? .signedIn : .signedOut
        guard ok else {
          state[id] = .idle
          return
        }
      }
      let saved = try library.progress(id)
      // 一度も最後まで取れていないサイトは保存したカーソルから、最後まで取れたことのあるサイトは先頭から、next が null になるまで辿る。
      // 既知の Shot の詳細を取り直すかどうかは、サイト用 JS が mitate.known で判断する。
      let initial = !saved.complete
      var cursor = initial ? saved.cursor : nil
      var done = 0
      var fresh = 0
      var pages = 0
      while true {
        pages += 1
        let page = try await runner.run(file, .list(cursor: cursor))
        if !page.errors.isEmpty {
          log("sync \(id): 不正な Shot \(page.errors.count) 件を除いた（\(page.errors.prefix(3).map(\.description).joined(separator: "; "))）")
        }
        // 最初の一巡は、ページの Shot と次のカーソルと complete を同じトランザクションで確定し、落ちても次はそのカーソルから再開する。
        let added = try library.save(page.shots, via: .list, progress: initial ? (id, page.next, page.next == nil) : nil)
        done += page.shots.count
        fresh += added.count
        state[id] = .syncing(done: done)
        await pipeline.enqueue(page.shots.map(\.id).filter(added.contains))
        guard let next = page.next else { break }
        cursor = next
      }
      try library.syncFinished(id)
      state[id] = .idle
      log("sync \(id): \(pages) ページ、\(done) 件（新規 \(fresh) 件）")
    } catch {
      let message = "\(error)"
      state[id] = .failed(message: message)
      log("sync \(id): 失敗 \(message)")
      do { try library.syncFailed(id, message: message) } catch { log("sync \(id): 失敗を記録できない \(error)") }
    }
  }

  // MARK: - live 検索

  /// サイトの検索に問い合わせ、返った Shot を `via = search` で保存して id を返す。
  /// 同じ検索語を 10 分以内に問い合わせていれば、問い合わせずに前回の id を返す。
  public func live(_ id: String, query: String, now: Date = Date()) async throws -> [String] {
    guard let file = files[id], file.meta.canSearch else { throw LiveError(message: "\(id) は検索を持たない") }
    let key = RateLimit.key(query)
    if let cached = try library.liveQuery(source: id, query: key), now.timeIntervalSince(cached.fetchedAt) < RateLimit.reuse {
      return cached.ids
    }
    if file.meta.loginURL != nil {
      if login[id] == nil || login[id] == .unknown {
        login[id] = try await runner.signedIn(file) ? .signedIn : .signedOut
      }
      guard login[id] == .signedIn else { throw LiveError(message: "ログインしていない") }
    }
    let limiter = limiter
    let page = try await runner.run(file, .search(query: query, cursor: nil)) { try limiter.admit(id) }
    if !page.errors.isEmpty {
      log("live \(id): 不正な Shot \(page.errors.count) 件を除いた（\(page.errors.prefix(3).map(\.description).joined(separator: "; "))）")
    }
    try library.save(page.shots, via: .search)
    let ids = page.shots.map(\.id)
    try library.setLiveQuery(source: id, query: key, ids: ids)
    return ids
  }
}
