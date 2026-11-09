import Foundation
import Testing
@testable import MitateCore

struct LibraryTests {
  let dir: URL
  let library: Library

  init() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("mitate-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    library = try Library(url: dir.appendingPathComponent("library.sqlite"))
  }

  func shot(_ source: String, _ id: String, kind: ShotKind = .image, title: String? = nil, text: String? = nil, tags: [String] = [], date: String? = nil) -> Shot {
    Shot(id: "\(source):\(id)", source: source, url: "https://\(source).example/\(id)", origin: nil, kind: kind,
         media: kind == .text ? nil : ShotMedia(src: "https://cdn.example/\(id).jpg", poster: nil, width: 800, height: 600),
         title: title, text: text, tags: tags, author: nil, publishedAt: date)
  }

  @Test func upsertKeepsFirstSeenAndListVia() throws {
    let first = Date(timeIntervalSince1970: 1_000_000)
    let fresh = try library.save([shot("a", "1", title: "Old title")], via: .list, now: first)
    #expect(fresh == ["a:1"])
    let again = try library.save([shot("a", "1", title: "New title")], via: .search, now: first.addingTimeInterval(3600))
    #expect(again.isEmpty)
    let row = try #require(try library.rows(["a:1"]).first)
    #expect(row.view.title == "New title")
    #expect(row.via == .list)
    #expect(try library.counts() == ["a": 1])
  }

  @Test func ftsFindsTrigramsShortTermsAndUpdates() throws {
    try library.save([
      shot("a", "1", title: "Toggle switch", tags: ["form"]),
      shot("a", "2", title: "トグルの例"),
      shot("b", "3", title: "Dark dashboard", text: "analytics"),
      shot("b", "4", kind: .text, title: "UI 設計", text: "余白の取り方"),
    ], via: .list)
    #expect(try library.search("toggle", sources: nil, kinds: nil, limit: 10) == ["a:1"])
    #expect(try library.search("TOGGLE", sources: nil, kinds: nil, limit: 10) == ["a:1"])
    #expect(try library.search("トグル", sources: nil, kinds: nil, limit: 10) == ["a:2"])
    #expect(try library.search("dark dashboard", sources: nil, kinds: nil, limit: 10) == ["b:3"])
    // 3 文字未満の語は like で引く。
    #expect(try library.search("UI", sources: nil, kinds: nil, limit: 10) == ["b:4"])
    #expect(try library.search("余白", sources: nil, kinds: nil, limit: 10) == ["b:4"])
    // 記号は演算子として解釈しない。
    #expect(try library.search("\"toggle OR", sources: nil, kinds: nil, limit: 10).isEmpty)
    #expect(try library.search("dark", sources: ["a"], kinds: nil, limit: 10).isEmpty)
    #expect(try library.search("dashboard", sources: nil, kinds: [.text], limit: 10).isEmpty)
    #expect(try library.search("dashboard", sources: nil, kinds: [.image, .video], limit: 10) == ["b:3"])
    try library.save([shot("a", "1", title: "Segmented control")], via: .list)
    #expect(try library.search("toggle", sources: nil, kinds: nil, limit: 10).isEmpty)
    #expect(try library.search("segmented", sources: nil, kinds: nil, limit: 10) == ["a:1"])
  }

  @Test func browseInterleavesSourcesNewestFirst() throws {
    try library.save([
      shot("a", "old", date: "2025-01-01T00:00:00Z"),
      shot("a", "new", date: "2026-01-01T00:00:00Z"),
      shot("b", "mid", date: "2025-06-01T00:00:00Z"),
    ], via: .list)
    #expect(try library.browse(sources: nil, kinds: nil, offset: 0, limit: 10) == ["a:new", "b:mid", "a:old"])
    #expect(try library.browse(sources: ["a"], kinds: nil, offset: 1, limit: 10) == ["a:old"])
  }

  @Test func browseShowsTextAtHalfTheRate() throws {
    try library.save([
      shot("a", "3", date: "2026-03-01T00:00:00Z"),
      shot("a", "2", date: "2026-02-01T00:00:00Z"),
      shot("a", "1", date: "2026-01-01T00:00:00Z"),
      shot("t", "new", kind: .text, text: "body", date: "2026-03-15T00:00:00Z"),
      shot("t", "old", kind: .text, text: "body", date: "2026-02-15T00:00:00Z"),
    ], via: .list)
    #expect(try library.browse(sources: nil, kinds: nil, offset: 0, limit: 10) == ["a:3", "t:new", "a:2", "a:1", "t:old"])
  }

  @Test func marksKeepSelectionOrderAndNotes() throws {
    try library.save([shot("a", "1"), shot("a", "2"), shot("a", "3")], via: .list)
    let t = Date(timeIntervalSince1970: 2_000_000)
    try library.setMark("a:2", selected: true, note: "余白", now: t)
    try library.setMark("a:1", selected: true, note: nil, now: t.addingTimeInterval(1))
    // メモだけ直しても、選んだ時刻は変わらない。
    try library.setMark("a:2", selected: true, note: "余白の取り方", now: t.addingTimeInterval(5))
    #expect(try library.selection() == ["a:2", "a:1"])
    #expect(try library.view("a:2")?.note == "余白の取り方")
    #expect(try library.view("a:2")?.selected == true)
    try library.setMark("a:2", selected: false, note: nil)
    #expect(try library.selection() == ["a:1"])
    try library.clearSelection()
    #expect(try library.selection().isEmpty)
  }

  @Test func cursorIsSavedWithThePage() throws {
    #expect(try library.progress("a") == SourceProgress(cursor: nil, complete: false, lastSyncedAt: nil, lastError: nil))
    try library.save([shot("a", "1")], via: .list, progress: ("a", "\"page-2\"", false))
    #expect(try library.progress("a").cursor == "\"page-2\"")
    #expect(try library.progress("a").complete == false)
    // 再開した 2 ページ目が最後なら complete になる。
    try library.save([shot("a", "2")], via: .list, progress: ("a", nil, true))
    let done = try library.progress("a")
    #expect(done.cursor == nil)
    #expect(done.complete)
    try library.syncFailed("a", message: "HTTP 500")
    #expect(try library.progress("a").lastError == "HTTP 500")
    try library.syncFinished("a")
    #expect(try library.progress("a").lastError == nil)
    #expect(try library.progress("a").complete)
  }

  @Test func knownAnswersInOrder() throws {
    try library.save([shot("a", "1"), shot("b", "2")], via: .list)
    #expect(try library.known(source: "a", ids: ["2", "1", "x"]) == [false, true, false])
    #expect(try library.known(source: "a", ids: []) == [])
  }

  @Test func vectorsRoundTripWithKind() throws {
    try library.save([shot("a", "1", kind: .video)], via: .list)
    try library.setVector("a:1", model: "m", vector: [0.25, -1, 3])
    let rows = try library.vectors(model: "m")
    #expect(rows.count == 1)
    #expect(rows[0].kind == .video)
    #expect(rows[0].vector == [0.25, -1, 3])
    #expect(try library.vectors(model: "other").isEmpty)
  }

  @Test func liveQueriesAreReused() throws {
    let t = Date(timeIntervalSince1970: 3_000_000)
    try library.setLiveQuery(source: "p", query: "toggle", ids: ["p:1", "p:2"], now: t)
    let cached = try #require(try library.liveQuery(source: "p", query: "toggle"))
    #expect(cached.ids == ["p:1", "p:2"])
    #expect(abs(cached.fetchedAt.timeIntervalSince(t)) < 0.01)
  }
}

struct RateLimitTests {
  @Test func spacingAndWindow() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(RateLimit.refusal(history: [], now: now) == nil)
    #expect(RateLimit.refusal(history: [now.addingTimeInterval(-3)], now: now) != nil)
    #expect(RateLimit.refusal(history: [now.addingTimeInterval(-5)], now: now) == nil)
    let six = (1 ... 6).map { now.addingTimeInterval(-Double($0) * 8) }
    #expect(RateLimit.refusal(history: six, now: now) != nil)
    #expect(RateLimit.refusal(history: Array(six.prefix(5)), now: now) == nil)
    #expect(RateLimit.key("  Toggle   Switch ") == "toggle switch")
  }
}

struct SourceFileTests {
  @Test func paceDefaultsAndValidates() throws {
    let base = "defineSource({ name: 'X', home: 'https://x.example/', login: null, async list() { return { shots: [], next: null }; }"
    #expect(try SourceFile.readMeta(id: "x", code: base + " });").pace == 1)
    #expect(try SourceFile.readMeta(id: "x", code: base + ", pace: 4000 });").pace == 4)
    #expect(throws: SourceError.self) { try SourceFile.readMeta(id: "x", code: base + ", pace: '4s' });") }
    #expect(throws: SourceError.self) { try SourceFile.readMeta(id: "x", code: base + ", pace: -1 });") }
  }
}

@MainActor
struct OnceTests {
  @Test func resumesOnlyOnceAndTimesOut() async throws {
    struct Late: Error {}
    var started = 0
    await #expect(throws: Late.self) {
      try await Once<Int>.wait(timeout: 0.2, timeoutError: Late()) { _ in started += 1 }
    }
    #expect(started == 1)
    let value = try await Once<Int>.wait(timeout: 5, timeoutError: Late()) { once in
      once.resume(.success(7))
      once.resume(.success(8))
      once.resume(.failure(Late()))
    }
    #expect(value == 7)
  }

  @Test func cancellationEndsTheWait() async {
    struct Late: Error {}
    let task = Task { @MainActor in
      try await Once<Void>.wait(timeout: 30, timeoutError: Late()) { _ in }
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
  }
}
