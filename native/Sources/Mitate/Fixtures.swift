import Foundation
import MitateCore

/// probe が書き出した実データの Shot から、ビューワーの型検査と開発用の応答を作る。
/// 応答の形は API.swift の Codable が決めるので、ここで encode したものが web 側の正解になる。
enum Fixtures {
  static func run(_ args: [String]) -> Int32 {
    guard args.count >= 2 else {
      fputs("usage: Mitate fixtures <out-dir> <shots.json>...\n", stderr)
      return 64
    }
    let out = URL(fileURLWithPath: args[0], isDirectory: true)
    let decoder = JSONDecoder()
    var bySource: [String: [Shot]] = [:]
    var order: [String] = []
    for path in args.dropFirst() {
      do {
        let shots = try decoder.decode([Shot].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for shot in shots {
          if bySource[shot.source] == nil { order.append(shot.source) }
          bySource[shot.source, default: []].append(shot)
        }
      } catch {
        fputs("\(path) を読めない: \(error)\n", stderr)
        return 1
      }
    }

    let perSource = 24
    var mixed: [ShotView] = []
    for round in 0 ..< perSource {
      for source in order {
        if let shot = bySource[source]?[safe: round] { mixed.append(view(shot, selected: mixed.count % 17 == 3)) }
      }
    }

    let statuses = order.enumerated().map { index, source in
      SourceStatus(
        id: source,
        name: source,
        home: bySource[source]?.first.flatMap { URL(string: $0.url) }.map { "\($0.scheme ?? "https")://\($0.host ?? "")/" } ?? "",
        icon: nil,
        canList: true,
        canSearch: source == "pinterest" || source == "x",
        login: source == "pinterest" || source == "x" || source == "aiforui" ? (index % 2 == 0 ? .signedIn : .signedOut) : .none,
        count: bySource[source]?.count ?? 0,
        sync: index == 1 ? .syncing(done: 40) : .idle,
        lastSyncedAt: "2026-11-08T06:00:00.000Z"
      )
    }

    let half = mixed.count / 2
    let events: [SearchEvent] = [
      .local(shots: Array(mixed.prefix(half))),
      .live(source: order.first ?? "pinterest", shots: Array(mixed.dropFirst(half).prefix(12))),
      .error(source: "x", message: "ログインしていない"),
      .done,
    ]

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let line = JSONEncoder()
    line.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      try encoder.encode(ShotsResponse(shots: mixed)).write(to: out.appendingPathComponent("browse.json"))
      try encoder.encode(SourcesResponse(sources: statuses)).write(to: out.appendingPathComponent("sources.json"))
      try encoder.encode(ShotsResponse(shots: mixed.filter(\.selected))).write(to: out.appendingPathComponent("selection.json"))
      let ndjson = try events.map { String(decoding: try line.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
      try Data(ndjson.utf8).write(to: out.appendingPathComponent("search.ndjson"))
    } catch {
      fputs("書き出せない: \(error)\n", stderr)
      return 1
    }
    print("wrote \(mixed.count) shots from \(order.count) sources to \(out.path)")
    return 0
  }

  /// 開発用の応答では、手元のサムネイルの代わりに元の画像を指す。
  static func view(_ shot: Shot, selected: Bool) -> ShotView {
    let aspect: Double? = {
      guard let w = shot.media?.width, let h = shot.media?.height, h > 0 else { return nil }
      return w / h
    }()
    return ShotView(
      id: shot.id,
      source: shot.source,
      url: shot.url,
      origin: shot.origin,
      kind: shot.kind,
      title: shot.title,
      text: shot.text,
      tags: shot.tags,
      author: shot.author,
      publishedAt: shot.publishedAt,
      thumb: shot.media?.poster ?? (shot.kind == .video ? nil : shot.media?.src),
      media: shot.media,
      aspect: aspect,
      colors: [],
      duplicates: 1,
      selected: selected,
      note: selected ? "余白の取り方" : nil
    )
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
