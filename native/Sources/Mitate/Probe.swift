import AppKit
import Foundation
import MitateCore

/// サイト用 JS を 1 本だけ実際に走らせ、返った Shot の形とメディアの取得可否を検証する。
/// サイト用 JS の完成条件は、このコマンドが終了コード 0 で終わること。
enum Probe {
  struct Options {
    var file: URL
    var query: String?
    var pages = 2
    var out: URL?
  }

  static func parse(_ args: [String]) -> Options? {
    var rest = args[...]
    guard let path = rest.popFirst() else { return nil }
    var options = Options(file: URL(fileURLWithPath: path))
    while let flag = rest.popFirst() {
      switch flag {
      case "--search": options.query = rest.popFirst()
      case "--pages": options.pages = rest.popFirst().flatMap(Int.init) ?? options.pages
      case "--out": options.out = rest.popFirst().map { URL(fileURLWithPath: $0) }
      default: return nil
      }
    }
    return options
  }

  @MainActor
  static func run(_ args: [String]) async -> Int32 {
    guard let options = parse(args) else {
      fputs("usage: Mitate probe <source.js> [--search <query>] [--pages <n>] [--out <shots.json>]\n", stderr)
      return 64
    }
    let source: SourceFile
    do {
      source = try SourceFile.load(options.file)
    } catch {
      print("FAIL 読み込み: \(error)")
      return 1
    }
    let meta = source.meta
    print("source \(meta.id)  name=\(meta.name)  home=\(meta.home.absoluteString)  list=\(meta.canList)  search=\(meta.canSearch)  login=\(meta.loginURL?.absoluteString ?? "-")  pace=\(Int(meta.pace * 1000))ms")

    // probe は手元の索引を持たないので、どの id も未知として答える。
    let runner = SourceRunner(known: { _, ids in ids.map { _ in false } })
    var problems: [String] = []
    var shots: [Shot] = []
    var cursor: String?
    let started = Date()

    if meta.loginURL != nil {
      do {
        print("signedIn \(try await runner.signedIn(source))")
      } catch {
        problems.append("login.check() が失敗: \(error)")
      }
    }

    for page in 1 ... max(options.pages, 1) {
      let call: SourceCall
      if let query = options.query {
        call = .search(query: query, cursor: cursor)
      } else if meta.canList {
        call = .list(cursor: cursor)
      } else {
        problems.append("search しか無いサイトなので --search <query> を付けて実行する")
        break
      }
      do {
        let t0 = Date()
        let result = try await runner.run(source, call)
        shots += result.shots
        print(String(format: "page %d  shots=%d  invalid=%d  next=%@  %.1fs", page, result.shots.count, result.errors.count, result.next.map { String($0.prefix(60)) } ?? "nil", Date().timeIntervalSince(t0)))
        for error in result.errors.prefix(5) { problems.append("不正な Shot \(error)") }
        if result.errors.count > 5 { problems.append("不正な Shot がほかに \(result.errors.count - 5) 件") }
        cursor = result.next
        if cursor == nil { break }
      } catch {
        problems.append("page \(page): \(error)")
        break
      }
    }

    let ids = shots.map(\.id)
    let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys
    if !duplicates.isEmpty { problems.append("id の重複 \(duplicates.count) 件: \(duplicates.prefix(3).joined(separator: ", "))") }
    if shots.isEmpty { problems.append("Shot が 0 件") }

    summarize(shots)
    problems += await checkMedia(shots, home: meta.home)

    if let out = options.out {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      do {
        try encoder.encode(shots).write(to: out)
        print("wrote \(shots.count) shots to \(out.path)")
      } catch {
        problems.append("--out に書けない: \(error)")
      }
    }

    print(String(format: "elapsed %.1fs", Date().timeIntervalSince(started)))
    if problems.isEmpty {
      print("PASS \(meta.id) \(shots.count) shots")
      return 0
    }
    for p in problems { print("FAIL \(p)") }
    return 1
  }

  static func summarize(_ shots: [Shot]) {
    guard !shots.isEmpty else { return }
    let n = Double(shots.count)
    func pct(_ f: (Shot) -> Bool) -> String { String(format: "%.0f%%", Double(shots.filter(f).count) / n * 100) }
    let kinds = Dictionary(grouping: shots, by: \.kind).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ")
    print("kinds \(kinds)")
    print("coverage title=\(pct { $0.title != nil }) origin=\(pct { $0.origin != nil }) text=\(pct { $0.text != nil }) tags=\(pct { !$0.tags.isEmpty }) author=\(pct { $0.author != nil }) date=\(pct { $0.publishedAt != nil }) size=\(pct { $0.media?.width != nil && $0.media?.height != nil }) poster=\(pct { $0.media?.poster != nil })")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for shot in shots.prefix(3) {
      if let data = try? encoder.encode(shot), let text = String(data: data, encoding: .utf8) { print("sample \(text.prefix(600))") }
    }
  }

  /// 画像と動画は WebKit の外（アプリのダウンローダーと、127.0.0.1 から開くビューワー）で取得するので、Cookie なしで取れるかを確かめる。
  static func checkMedia(_ shots: [Shot], home: URL) async -> [String] {
    var urls: [(String, String)] = []
    for kind in ShotKind.allCases {
      for shot in shots.filter({ $0.kind == kind && $0.media != nil }).prefix(3) {
        if let m = shot.media {
          urls.append((shot.id, m.src))
          if let poster = m.poster { urls.append((shot.id, poster)) }
        }
      }
    }
    var problems: [String] = []
    for (id, url) in urls {
      let plain = await fetchStatus(url, referer: nil)
      let withReferer = plain.ok ? plain : await fetchStatus(url, referer: home.absoluteString)
      print("media \(plain.ok ? "ok" : withReferer.ok ? "referer" : "NG") \(plain.status)/\(withReferer.status) \(plain.type) \(url.prefix(110))")
      if !plain.ok && !withReferer.ok { problems.append("メディアを取得できない \(id): \(url)") }
    }
    return problems
  }

  struct Fetched { let ok: Bool; let status: Int; let type: String }

  static func fetchStatus(_ url: String, referer: String?) async -> Fetched {
    guard let u = URL(string: url) else { return Fetched(ok: false, status: -1, type: "-") }
    var request = URLRequest(url: u, timeoutInterval: 20)
    request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(SourceRunner.safariApplicationName)", forHTTPHeaderField: "User-Agent")
    if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let http = response as? HTTPURLResponse
      let status = http?.statusCode ?? -1
      let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "-"
      let isMedia = ["image/", "video/", "application/octet-stream", "binary/", "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl"].contains { type.lowercased().hasPrefix($0) }
      return Fetched(ok: (200 ..< 300).contains(status) && isMedia, status: status, type: type)
    } catch {
      return Fetched(ok: false, status: -1, type: "error")
    }
  }
}
