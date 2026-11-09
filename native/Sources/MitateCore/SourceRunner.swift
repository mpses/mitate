import AppKit
import Foundation
import WebKit

public enum SourceCall: Sendable {
  case list(cursor: String?)
  case search(query: String, cursor: String?)
}

public struct SourcePage: Sendable {
  public let shots: [Shot]
  public let errors: [ShotError]
  /// 次のページのカーソル。JSON 文字列のまま持ち、次の呼び出しへそのまま返す。
  public let next: String?
}

/// サイト用 JS を、そのサイトのページを開いた隠しウィンドウの WebKit で実行する。
/// ページのスクリプトから隔離した content world で動かすので、fetch はサイト自身のオリジンと Cookie で飛ぶ。
/// 呼び出しはサイトごとに直列にし、前の呼び出しの終わりから `pace` を空けてから次を始める。
@MainActor
public final class SourceRunner: NSObject, WKNavigationDelegate {
  public static let world = WKContentWorld.world(name: "mitate")
  public nonisolated static let safariApplicationName = "Version/26.0 Safari/605.1.15"
  /// `mitate.known` の受け口。サイト用 JS の content world にだけ登録する
  static let knownHandlerName = "mitateKnown"
  static let pageSize = NSSize(width: 1440, height: 1000)

  /// サイト内の id（`source:` の接頭辞なし）が手元にあるかを、渡した順に返す。メインスレッドの外で呼ぶ。
  public typealias Known = @Sendable (_ source: String, _ ids: [String]) throws -> [Bool]
  /// 順番が来て問い合わせを始める直前に呼ぶ判定。投げたら問い合わせずに、その例外で終わる。
  public typealias Admit = @Sendable () throws -> Void

  @MainActor
  private final class Tab {
    let web: WKWebView
    /// 呼び出しの間だけ見せる
    let window: AwakeWindow
    var loadedHome = false
    /// ページの読み込みを待っているもの
    var navigations: [Once<Void>] = []
    /// 実行中の JS
    var calls: [Once<Any?>] = []
    init(web: WKWebView, window: AwakeWindow) {
      self.web = web
      self.window = window
    }
  }

  private let dataStore: WKWebsiteDataStore
  private let known: Known
  private var tabs: [String: Tab] = [:]
  private let lanes = SiteLanes()
  /// 隠しタブに付ける、読み込みを止める規則。止める資源の組ごとに一度だけ作る
  private var blockers: [String: Task<WKContentRuleList?, Error>] = [:]
  public var callTimeout: TimeInterval = 90
  /// 呼び出しが途切れてからページを閉じるまでの秒数。同期のページ送りと、続けて打つ live 検索の間は開いたままにする。
  public var idleTimeout: TimeInterval = 20
  /// 同時に開いておく隠しタブの目安。同期が並べて取るサイトの数。使い終わったタブは、別のサイトのタブを開く前に閉じる（1 つで 600MB を超えるサイトがある）。
  /// 使用中のタブは閉じないので、live 検索やログインの確認と重なると超える
  static let openTabLimit = Syncer.parallel

  public init(dataStore: WKWebsiteDataStore? = nil, known: @escaping Known) {
    self.dataStore = dataStore ?? .default()
    self.known = known
  }

  public static func configuration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = dataStore
    config.applicationNameForUserAgent = safariApplicationName
    config.preferences.inactiveSchedulingPolicy = .none
    config.mediaTypesRequiringUserActionForPlayback = .all
    return config
  }

  public func run(_ source: SourceFile, _ call: SourceCall, admit: Admit? = nil) async throws -> SourcePage {
    try await serialized(source, label: Self.label(call), admit: admit) {
      try await self.perform(source, call)
    }
  }

  /// `reload` が真なら、ページを開き直してから確かめる。ログインの途中など、Cookie が変わったあとに使う。
  public func signedIn(_ source: SourceFile, reload: Bool = false) async throws -> Bool {
    guard source.meta.loginURL != nil else { return true }
    return try await serialized(source, label: "signedIn", admit: nil) {
      if reload { await self.discard(source.meta.id, reason: "ログイン状態を確かめ直すため開き直す") }
      let tab = try await self.ready(source)
      let result = try await self.call(source, tab: tab, body: Self.body(code: source.code, tail: "return !!(await __def.v.login.check());"), arguments: [:])
      guard let flag = result as? Bool else { throw SourceError.script(source.meta.id, "login.check() が真偽値を返していない") }
      return flag
    }
  }

  // MARK: - 呼び出しの列

  private static func label(_ call: SourceCall) -> String {
    switch call {
    case .list: "list"
    case .search: "search"
    }
  }

  private func serialized<T>(_ source: SourceFile, label: String, admit: Admit?, _ body: () async throws -> T) async throws -> T {
    let id = source.meta.id
    // 開いたままのページは、サイトごとに WebContent のプロセスと数百 MB を持ち続ける。
    let after = idleTimeout
    let idle = SiteLanes.Idle(after: after) { [weak self] early in
      await self?.discard(id, reason: early ? "隠しタブが \(Self.openTabLimit) 個に達したので先に閉じる" : "\(Int(after)) 秒呼び出しが無かった")
    }
    return try await lanes.run(id, pace: source.meta.pace, label: label, admit: admit, idle: idle) {
      // 呼び出しの間は窓を隠し、サイトのページの描画と動画の再生を止める。
      defer { self.tabs[id]?.window.hide() }
      do {
        return try await body()
      } catch {
        // 時間切れと取り消しでは、ページの JS と fetch が止まらずに残るので、ページを閉じてから列を空ける。
        if Self.leavesPageRunning(error) { await self.discard(id, reason: "\(label) が終わらなかった（\(error)）") }
        throw error
      }
    }
  }

  private static func leavesPageRunning(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case SourceError.timeout = error { return true }
    return false
  }

  /// ページを about:blank へ移して前の文書の JS と読み込みを止め、窓を閉じる。次の呼び出しは新しいタブで home から開く。
  /// 呼んだ Task が取り消されていても閉じ終えるまで進むよう、別の Task で行う。
  private func discard(_ id: String, reason: String) async {
    guard tabs[id] != nil else { return }
    await Task { @MainActor in
      guard let tab = self.tabs[id] else { return }
      let error = SourceError.navigation(id, reason)
      for once in tab.navigations { once.resume(.failure(error)) }
      for once in tab.calls { once.resume(.failure(error)) }
      tab.navigations.removeAll()
      tab.calls.removeAll()
      tab.web.load(URLRequest(url: URL(string: "about:blank")!))
      do {
        try await self.waitForNavigation(tab, id: id, timeout: 10)
      } catch {
        log("runner \(id): about:blank へ移れないまま閉じる（\(error)）")
      }
      self.tabs[id] = nil
      tab.web.configuration.userContentController.removeAllScriptMessageHandlers()
      tab.window.close()
      log("runner \(id): ページを閉じた（\(reason)）")
    }.value
    Self.drainAppKitPool(id)
  }

  /// MainActor の Task で閉じた窓と WKWebView は、AppKit が次のイベントで autorelease pool を空にするまで残って WebContent も終わらないので、空のイベントを送る。
  private static func drainAppKitPool(_ id: String) {
    guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) else {
      log("runner \(id): イベントを作れないので、閉じたページは次のイベントまで残る")
      return
    }
    NSApp.postEvent(event, atStart: false)
  }

  private func perform(_ source: SourceFile, _ call: SourceCall) async throws -> SourcePage {
    let tab = try await ready(source)
    let raw = try await evaluate(source, tab: tab, call: call)
    var shots: [Shot] = []
    var errors: [ShotError] = []
    for (index, item) in raw.shots.enumerated() {
      switch item.validated(source: source.meta.id, index: index) {
      case let .success(shot): shots.append(shot)
      case let .failure(error): errors.append(error)
      }
    }
    if let goto = raw.goto {
      guard let url = URL(string: goto), isHTTP(goto) else { throw SourceError.script(source.meta.id, "goto が絶対 URL ではない: \(goto)") }
      // goto は同じ呼び出しの続きだが、サイトへの読み込みが増えるので pace を空ける。
      try await Task.sleep(nanoseconds: UInt64(source.meta.pace * 1_000_000_000))
      try await load(url, in: tab, source: source)
      let rest = try await perform(source, continuing(call, cursor: raw.next))
      return SourcePage(shots: shots + rest.shots, errors: errors + rest.errors, next: rest.next)
    }
    return SourcePage(shots: shots, errors: errors, next: raw.next)
  }

  // MARK: - ページ

  private func ready(_ source: SourceFile) async throws -> Tab {
    let tab: Tab
    if let open = tabs[source.meta.id] {
      tab = open
    } else {
      // 同期の始めには、使い終わって閉じるのを待つタブが全サイト分重なるので、古いものから先に閉じる。
      for site in lanes.idleSites() where tabs.count >= Self.openTabLimit {
        await lanes.runIdleNow(site)
      }
      tab = try await makeTab(for: source)
    }
    tab.window.show()
    if !tab.loadedHome || tab.web.url == nil {
      let started = Date()
      try await load(source.meta.home, in: tab, source: source)
      tab.loadedHome = true
      log(String(format: "runner %@: ページを開いた（%.1f 秒）", source.meta.id, Date().timeIntervalSince(started)))
    }
    return tab
  }

  /// ページは AwakeWindow に置き、呼び出しの間だけ見せる。ページの大きさは `pageSize`。
  private func makeTab(for source: SourceFile) async throws -> Tab {
    guard let screen = NSScreen.screens.first else { throw SourceError.navigation(source.meta.id, "画面が無いので隠しタブを置けない") }
    let config = Self.configuration(dataStore: dataStore)
    config.userContentController.add(try await blocker(for: source))
    config.userContentController.addScriptMessageHandler(KnownHandler(source: source.meta.id, known: known), contentWorld: Self.world, name: Self.knownHandlerName)
    let web = WKWebView(frame: NSRect(origin: .zero, size: Self.pageSize), configuration: config)
    web.navigationDelegate = self
    let tab = Tab(web: web, window: AwakeWindow(web: web, screen: screen))
    tabs[source.meta.id] = tab
    return tab
  }

  /// サイト用 JS は DOM と fetch の応答しか読まないので描画にだけ使う資源を止め、画像を読み込むまで 0 の寸法（naturalWidth）を読む JS には画像を残す。
  static func blockedResourceTypes(code: String) -> [String] {
    let readsImageSize = code.range(of: #"\bnatural(Width|Height)\b"#, options: .regularExpression) != nil
    return readsImageSize ? ["media", "font"] : ["image", "media", "font"]
  }

  private func blocker(for source: SourceFile) async throws -> WKContentRuleList {
    let types = Self.blockedResourceTypes(code: source.code)
    let identifier = "mitate-hidden-tab-block-" + types.joined(separator: "-")
    let compiling: Task<WKContentRuleList?, Error>
    if let existing = blockers[identifier] {
      compiling = existing
    } else {
      let rules: [[String: Any]] = [["trigger": ["url-filter": ".*", "resource-type": types], "action": ["type": "block"]]]
      let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
      compiling = Task { @MainActor in
        try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
      }
      blockers[identifier] = compiling
    }
    let failure: String
    do {
      if let list = try await compiling.value { return list }
      failure = "WKContentRuleListStore が規則を返さなかった"
    } catch {
      failure = "\(error)"
    }
    blockers[identifier] = nil
    throw SourceError.navigation(source.meta.id, "読み込みを止める規則 \(identifier) を作れない（\(failure)）")
  }

  private func load(_ url: URL, in tab: Tab, source: SourceFile) async throws {
    tab.web.load(URLRequest(url: url))
    try await waitForNavigation(tab, id: source.meta.id, timeout: 45)
    // bot 判定のページを挟むサイトは、サイト自身のホストへ戻るまで待つ。
    let deadline = Date().addingTimeInterval(20)
    while !sameSite(tab.web.url, url), Date() < deadline {
      try await waitForNavigation(tab, id: source.meta.id, timeout: deadline.timeIntervalSinceNow)
    }
    guard sameSite(tab.web.url, url) else {
      throw SourceError.navigation(source.meta.id, "\(url.absoluteString) を開いたが \(tab.web.url?.absoluteString ?? "nil") に留まった")
    }
  }

  private func sameSite(_ a: URL?, _ b: URL) -> Bool {
    guard let ha = a?.host?.lowercased(), let hb = b.host?.lowercased() else { return false }
    func base(_ h: String) -> String { h.split(separator: ".").suffix(2).joined(separator: ".") }
    return base(ha) == base(hb)
  }

  /// 読み込みの完了・失敗・時間切れ・取り消し・ページを閉じたことのうち、最初に起きたもので一度だけ戻る。
  private func waitForNavigation(_ tab: Tab, id: String, timeout: TimeInterval) async throws {
    try await Once<Void>.wait(timeout: timeout, timeoutError: SourceError.timeout(id, "ページの読み込み（\(Int(timeout)) 秒）")) { once in
      tab.navigations.append(once)
    }
  }

  private func settle(_ web: WKWebView, error: Error?) {
    guard let tab = tabs.values.first(where: { $0.web === web }) else { return }
    let waiting = tab.navigations
    tab.navigations.removeAll()
    for once in waiting {
      if let error { once.resume(.failure(error)) } else { once.resume(.success(())) }
    }
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    settle(webView, error: nil)
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if (error as NSError).code == NSURLErrorCancelled { return }
    settle(webView, error: error)
  }

  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if (error as NSError).code == NSURLErrorCancelled { return }
    settle(webView, error: error)
  }

  // MARK: - JS

  private struct RawPage: Decodable {
    let shots: [RawShot]
    let next: String?
    let goto: String?
  }

  private func evaluate(_ source: SourceFile, tab: Tab, call: SourceCall) async throws -> RawPage {
    let tail = """
      const src = __def.v;
      const c = cursor == null ? null : JSON.parse(cursor);
      const page = op === 'list' ? await src.list(c) : await src.search(query, c);
      if (!page || !Array.isArray(page.shots)) throw new Error(op + ' が { shots, next } を返していない');
      return JSON.stringify({ shots: page.shots, next: page.next == null ? null : JSON.stringify(page.next), goto: page.goto ?? null });
      """
    let arguments: [String: Any]
    switch call {
    case let .list(cursor):
      guard source.meta.canList else { throw SourceError.invalid(source.meta.id, "list が無い") }
      arguments = ["op": "list", "query": NSNull(), "cursor": cursor ?? NSNull()]
    case let .search(query, cursor):
      guard source.meta.canSearch else { throw SourceError.invalid(source.meta.id, "search が無い") }
      arguments = ["op": "search", "query": query, "cursor": cursor ?? NSNull()]
    }
    let result = try await self.call(source, tab: tab, body: Self.body(code: source.code, tail: tail), arguments: arguments)
    guard let text = result as? String, let data = text.data(using: .utf8) else {
      throw SourceError.script(source.meta.id, "結果が JSON 文字列ではない")
    }
    do {
      return try JSONDecoder().decode(RawPage.self, from: data)
    } catch {
      throw SourceError.script(source.meta.id, "結果の形が違う: \(error)")
    }
  }

  /// JS の完了・時間切れ・取り消し・ページを閉じたことのうち、最初に起きたもので一度だけ戻る。
  private func call(_ source: SourceFile, tab: Tab, body: String, arguments: [String: Any]) async throws -> Any? {
    let id = source.meta.id
    return try await Once<Any?>.wait(timeout: callTimeout, timeoutError: SourceError.timeout(id, "JS の実行（\(Int(callTimeout)) 秒）")) { once in
      tab.calls.append(once)
      // 終わらない JS の完了ハンドラーがタブを掴んで WKWebView を残さないよう、タブは弱く持つ。
      tab.web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Self.world) { [weak tab] result in
        tab?.calls.removeAll { $0 === once }
        switch result {
        case let .success(value): once.resume(.success(value))
        case let .failure(error):
          let ns = error as NSError
          once.resume(.failure(SourceError.script(id, ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ns.localizedDescription)))
        }
      }
    }
  }

  private func continuing(_ call: SourceCall, cursor: String?) -> SourceCall {
    switch call {
    case .list: .list(cursor: cursor)
    case let .search(query, _): .search(query: query, cursor: cursor)
    }
  }

  static let prelude = """
    const __def = { v: null };
    const defineSource = (d) => { __def.v = d; };
    const mitate = {
      sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
      abs: (u, base) => new URL(u, base ?? location.href).href,
      async text(u, init) {
        const r = await fetch(u, init);
        if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + u);
        return r.text();
      },
      async json(u, init) {
        const r = await fetch(u, init);
        if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + u);
        return r.json();
      },
      async doc(u, init) {
        return new DOMParser().parseFromString(await mitate.text(u, init), 'text/html');
      },
      async waitFor(fn, ms = 15000) {
        const t = Date.now();
        for (;;) {
          const v = await fn();
          if (v) return v;
          if (Date.now() - t > ms) throw new Error('waitFor: ' + ms + 'ms 以内に条件を満たさなかった');
          await new Promise((r) => setTimeout(r, 200));
        }
      },
      async known(ids) {
        if (!Array.isArray(ids) || ids.some((x) => typeof x !== 'string')) throw new Error('mitate.known は文字列の配列を受け取る');
        if (ids.length === 0) return [];
        const flags = await window.webkit.messageHandlers.\(knownHandlerName).postMessage(ids);
        if (!Array.isArray(flags) || flags.length !== ids.length) throw new Error('mitate.known の応答の形が違う');
        return flags.map((f) => f === true);
      },
    };
    """

  static func body(code: String, tail: String) -> String {
    "\(prelude)\n\(code)\n;\nif (!__def.v) throw new Error('defineSource が呼ばれていない');\n\(tail)"
  }
}

/// サイトごとの呼び出しの列。同じサイトの呼び出しを届いた順に 1 つずつ通し、前の呼び出しの終わりから `pace` 秒空けて次を始める。
@MainActor
final class SiteLanes {
  /// 呼び出しの後に列が空いたまま `after` 秒たったら、列の順番の中で一度だけ走らせる片付け。`early` は時間を待たずに走らせたとき真
  struct Idle {
    let after: TimeInterval
    let run: @MainActor (_ early: Bool) async -> Void
  }

  private struct Pending {
    let serial: Int
    let idle: Idle
    let since: Date
    let timer: Task<Void, Never>
  }

  private final class Lane {
    var busy = false
    /// 順番を待つ呼び出し。片付けはここに並ばない
    var queue: [CheckedContinuation<Void, Never>] = []
    var lastEnd: Date?
    /// 予約中の片付け。走り出すか、次の呼び出しが届いたら外す
    var pending: Pending?
  }

  private var lanes: [String: Lane] = [:]
  private var serial = 0

  /// `admit` は順番が来て `body` を始める直前に呼ぶ。投げたら `body` を走らせず、その例外で終わる。
  /// `idle` は、この呼び出しの後ろに待つ呼び出しが無いときだけ予約し、次の呼び出しが届いたら取り消す。
  func run<T>(_ id: String, pace: TimeInterval, label: String, admit: SourceRunner.Admit?, idle: Idle? = nil, _ body: () async throws -> T) async throws -> T {
    let lane = lanes[id] ?? Lane()
    lanes[id] = lane
    lane.pending?.timer.cancel()
    lane.pending = nil
    if lane.busy {
      await withCheckedContinuation { lane.queue.append($0) }
    } else {
      lane.busy = true
    }
    defer {
      if let idle, lane.queue.isEmpty { schedule(idle, on: lane) }
      release(lane)
    }
    if let last = lane.lastEnd {
      let wait = pace - Date().timeIntervalSince(last)
      if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
    let gap = lane.lastEnd.map { String(format: "%.3f", Date().timeIntervalSince($0)) } ?? "-"
    do {
      try admit?()
    } catch {
      log("runner \(id) \(label): 問い合わせない \(Timestamp.string())（\(error)）")
      throw error
    }
    log("runner \(id) \(label): 開始 \(Timestamp.string()) 前の終わりから \(gap) 秒（pace \(pace) 秒）")
    defer { lane.lastEnd = Date() }
    return try await body()
  }

  /// 片付けを予約したまま空いているサイトを、予約の古い順に返す。
  func idleSites() -> [String] {
    lanes.compactMap { id, lane in lane.busy ? nil : lane.pending.map { (id, $0.since) } }.sorted { $0.1 < $1.1 }.map(\.0)
  }

  /// 予約中の片付けを、時間を待たずに今走らせる。呼び出し中のサイトと、予約の無いサイトには何もしない。
  func runIdleNow(_ id: String) async {
    guard let lane = lanes[id] else { return }
    await runPending(lane, serial: nil)
  }

  private func schedule(_ idle: Idle, on lane: Lane) {
    serial += 1
    let serial = serial
    let timer = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(idle.after * 1_000_000_000)) } catch { return }
      await self?.runPending(lane, serial: serial)
    }
    lane.pending = Pending(serial: serial, idle: idle, since: Date(), timer: timer)
  }

  /// `serial` が nil なら今の予約を、そうでなければその番号の予約が残っているときだけ走らせる。
  private func runPending(_ lane: Lane, serial: Int?) async {
    guard !lane.busy, let pending = lane.pending, serial == nil || pending.serial == serial else { return }
    lane.pending = nil
    if serial == nil { pending.timer.cancel() }
    lane.busy = true
    defer { release(lane) }
    await pending.idle.run(serial == nil)
  }

  private func release(_ lane: Lane) {
    if lane.queue.isEmpty { lane.busy = false } else { lane.queue.removeFirst().resume() }
  }
}

/// `mitate.known(ids)` に答える。サイト用 JS の content world にだけ登録するので、ページ側からは呼べない。
@MainActor
private final class KnownHandler: NSObject, WKScriptMessageHandlerWithReply {
  let source: String
  let known: SourceRunner.Known

  init(source: String, known: @escaping SourceRunner.Known) {
    self.source = source
    self.known = known
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
    guard let ids = message.body as? [String] else {
      replyHandler(nil, "mitate.known は文字列の配列を受け取る")
      return
    }
    // 索引の書き込みを待つことがあるので、メインスレッドを塞がないよう外で引く。
    let known = known
    let source = source
    Task.detached {
      let result = Result { try known(source, ids) }
      await MainActor.run {
        switch result {
        case let .success(flags): replyHandler(flags, nil)
        case let .failure(error): replyHandler(nil, "mitate.known が失敗: \(error)")
        }
      }
    }
  }
}

/// 一度だけ再開する継続。完了・時間切れ・取り消し・ページを閉じたことのどれが先に来ても、2 回目以降は無視する。
@MainActor
final class Once<T> {
  private var continuation: CheckedContinuation<T, Error>?
  private var timer: Task<Void, Never>?

  func resume(_ result: Result<T, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    continuation.resume(with: result)
  }

  /// `start` に自分を渡して待つ。`timeout` 秒たつか、待っている Task が取り消されたら、エラーで戻る。
  static func wait(timeout: TimeInterval, timeoutError: Error, start: (Once<T>) -> Void) async throws -> T {
    let once = Once<T>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        once.continuation = continuation
        once.timer = Task { @MainActor in
          do { try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000)) } catch { return }
          once.resume(.failure(timeoutError))
        }
        if Task.isCancelled {
          once.resume(.failure(CancellationError()))
          return
        }
        start(once)
      }
    } onCancel: {
      Task { @MainActor in once.resume(.failure(CancellationError())) }
    }
  }
}
