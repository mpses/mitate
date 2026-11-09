import CoreGraphics
import Foundation
import ImageIO

public enum EngineError: Error, CustomStringConvertible {
  case notFound(String)
  case badRequest(String)
  case unavailable(String)

  public var description: String {
    switch self {
    case let .notFound(m), let .badRequest(m), let .unavailable(m): m
    }
  }
}

/// 索引の操作の全部。HTTP の殻と MCP はこれだけを使う。
public final class Engine: EngineAPI, @unchecked Sendable {
  public let paths: Paths
  public let library: Library
  public let runner: SourceRunner
  private let files: [String: SourceFile]
  /// 読み込みに失敗したサイト用 JS と理由
  private let broken: [String: String]
  private let order: [String]
  private let embedder: Embedder?
  private let index: VectorIndex?
  private let fetcher = MediaFetcher()
  private let thumbnailer: Thumbnailer
  private let pipeline: Pipeline
  private let syncer: Syncer

  static let candidates = 300

  /// 同梱分と利用者分のサイト用 JS を読む。同じ id は利用者分を優先し、読めないファイルはそのサイトだけを failed にする。
  @MainActor
  public init(paths: Paths, resources: Resources, embedder: Embedder?) throws {
    try paths.prepare()
    self.paths = paths
    library = try Library(url: paths.library)
    var files: [String: SourceFile] = [:]
    var broken: [String: String] = [:]
    for dir in [resources.sources, paths.userSources] {
      for url in try SourceFile.files(in: dir) {
        let id = url.deletingPathExtension().lastPathComponent
        do {
          files[id] = try SourceFile.load(url)
          broken[id] = nil
        } catch {
          files[id] = nil
          broken[id] = "\(url.path): \(error)"
          log("source \(id): 読み込みに失敗 \(error)")
        }
      }
    }
    self.files = files
    self.broken = broken
    order = Set(files.keys).union(broken.keys).sorted()
    self.embedder = embedder
    let library = library
    runner = SourceRunner(known: { source, ids in try library.known(source: source, ids: ids) })
    if let embedder {
      let index = VectorIndex(dimension: embedder.dimension)
      for (id, kind, vector) in try library.vectors(model: embedder.model) { index.set(id, kind: kind, vector) }
      self.index = index
      log("embedder \(embedder.model): \(index.count) 件の埋め込みを読んだ")
    } else {
      index = nil
      log("embedder: 埋め込みモデル未設定。検索は全文検索だけで行う")
    }
    thumbnailer = Thumbnailer(fetcher: fetcher, paths: paths)
    pipeline = Pipeline(library: library, thumbnailer: thumbnailer, embedder: embedder, index: index, homes: files.mapValues(\.meta.home))
    syncer = try Syncer(library: library, runner: runner, files: files, pipeline: pipeline)
  }

  /// 待ち行列と定期取得を始め、無い favicon を取る。
  public func start() async throws {
    try await pipeline.start()
    await syncer.schedule()
    Task { await self.fetchIcons() }
  }

  private func fetchIcons() async {
    for id in order {
      guard let file = files[id], !FileManager.default.fileExists(atPath: paths.iconFile(source: id).path) else { continue }
      do {
        try await thumbnailer.favicon(home: file.meta.home).write(to: paths.iconFile(source: id), options: .atomic)
      } catch {
        log("icon \(id): \(error)")
      }
    }
  }

  // MARK: - EngineAPI

  public func sources() async -> [SourceStatus] {
    // 一覧そのものは返し、読めなかったことは各サイトの状態に出す。
    var counts: [String: Int] = [:]
    var progress: [String: SourceProgress] = [:]
    var countError: String?
    do {
      counts = try library.counts()
      progress = try library.allProgress()
    } catch {
      countError = "件数を読めない: \(error)"
      log("sources: \(countError!)")
    }
    var out: [SourceStatus] = []
    for id in order {
      let icon = FileManager.default.fileExists(atPath: paths.iconFile(source: id).path) ? "/media/icon-\(id).png" : nil
      guard let file = files[id] else {
        out.append(SourceStatus(id: id, name: id, home: "", icon: icon, canList: false, canSearch: false, login: .unknown, count: counts[id] ?? 0, sync: .failed(message: broken[id] ?? "読み込めない"), lastSyncedAt: nil))
        continue
      }
      let status = await syncer.status(id)
      out.append(SourceStatus(
        id: id,
        name: file.meta.name,
        home: file.meta.home.absoluteString,
        icon: icon,
        canList: file.meta.canList,
        canSearch: file.meta.canSearch,
        login: status.login,
        count: counts[id] ?? 0,
        sync: countError.map { .failed(message: $0) } ?? status.sync,
        lastSyncedAt: progress[id]?.lastSyncedAt
      ))
    }
    return out
  }

  public func browse(sources: Set<String>?, offset: Int, limit: Int) async throws -> [ShotView] {
    try library.views(library.browse(sources: sources, kinds: nil, offset: offset, limit: limit))
  }

  public func search(_ query: String, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int, live: Bool) -> AsyncThrowingStream<SearchEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
          // 埋め込みモデルが無いときは全文検索の結果だけで並べ、live はサイトが返した順に流す（起動時に記録済み）。
          var vector: [Float]?
          do {
            if !text.isEmpty { vector = try await self.queryVector(text) }
          } catch EmbedderError.notConfigured {}
          continuation.yield(.local(shots: try self.localSearch(text, vector: vector, sources: sources, kinds: kinds, limit: limit)))
          if live, !text.isEmpty { await self.liveSearch(text, vector: vector, sources: sources, kinds: kinds, limit: limit) { continuation.yield($0) } }
          continuation.yield(.done)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// FTS の bm25 の上位と、検索語の埋め込みに近い上位を RRF でまとめ、重複をまとめてサイトを交互にする。
  func localSearch(_ text: String, vector: [Float]?, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int) throws -> [ShotView] {
    guard !text.isEmpty else { return try arrange(library.browse(sources: sources, kinds: kinds, offset: 0, limit: limit), kinds: kinds, limit: limit, interleave: false) }
    var lists = [(ids: try library.search(text, sources: sources, kinds: kinds, limit: Self.candidates), weight: 1.0)]
    if let vector {
      for group in Ranking.modalities(of: kinds) {
        lists.append((ids: try nearest(vector, sources: sources, kinds: group.kinds, limit: Self.candidates).map(\.id), weight: group.weight))
      }
    }
    return try arrange(Ranking.fuse(weighted: lists), kinds: kinds, limit: limit, interleave: true)
  }

  private func liveSearch(_ text: String, vector: [Float]?, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int, emit: @escaping (SearchEvent) -> Void) async {
    let targets = order.filter { id in files[id]?.meta.canSearch == true && (sources?.contains(id) ?? true) }
    await withTaskGroup(of: SearchEvent.self) { group in
      for id in targets {
        group.addTask {
          do {
            let ids = try await self.syncer.live(id, query: text)
            await self.pipeline.ready(ids, timeout: 8)
            return .live(source: id, shots: try self.arrange(self.closest(ids, to: vector), kinds: kinds, limit: limit, interleave: false))
          } catch {
            return .error(source: id, message: "\(error)")
          }
        }
      }
      for await event in group { emit(event) }
    }
  }

  /// 検索語に近い順（種類の組ごとの順位を RRF でまとめる）。埋め込みが間に合わなかったものは、サイトが返した順で末尾へ。
  private func closest(_ ids: [String], to vector: [Float]?) -> [String] {
    guard let vector, let index else { return ids }
    let scored = ids.compactMap { id in index.entry(id).map { (id: id, kind: $0.kind, score: Ranking.dot($0.vector, vector)) } }
    let known = Set(scored.map(\.id))
    return Ranking.acrossModalities(scored) + ids.filter { !known.contains($0) }
  }

  public func similar(to target: SimilarTarget, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int) async throws -> [ShotView] {
    guard let embedder, let index else { throw EmbedderError.notConfigured }
    let vector: [Float]
    var exclude: String?
    switch target {
    case let .shot(id):
      guard try library.view(id) != nil else { throw EngineError.notFound("\(id) は手元に無い") }
      guard let v = index.vector(id) else { throw EngineError.unavailable("\(id) の埋め込みはまだ計算していない") }
      vector = v
      exclude = id
    case let .image(data):
      vector = try await Imaging.work { Ranking.normalized(try embedder.embed(image: try Imaging.decode(data, maxSide: Thumbnailer.maxSide, label: "送られた画像"))) }
    }
    // 自分自身と、自分とほぼ同じ画像は除く。
    let near = try nearest(vector, sources: sources, kinds: kinds, limit: limit * 3 + 20).filter { $0.id != exclude && (exclude == nil || $0.score < 0.96) }
    return try arrange(near.map(\.id), kinds: kinds, limit: limit, interleave: false)
  }

  public func shot(_ id: String) async throws -> ShotView {
    guard let view = try library.view(id) else { throw EngineError.notFound("\(id) は手元に無い") }
    return view
  }

  public func selection() async throws -> [ShotView] {
    try library.views(library.selection())
  }

  public func setSelection(_ id: String, _ update: SelectionUpdate) async throws -> ShotView {
    guard try library.view(id) != nil else { throw EngineError.notFound("\(id) は手元に無い") }
    try library.setMark(id, selected: update.selected, note: update.note)
    return try await shot(id)
  }

  public func clearSelection() async throws {
    try library.clearSelection()
  }

  public func sync(source: String?) async {
    await syncer.request(source)
  }

  public func signInChanged(source: String) async {
    await syncer.refreshLogin(source)
  }

  public func sheet(ids: [String]) async throws -> Data {
    guard !ids.isEmpty else { throw EngineError.badRequest("ids が空") }
    var views = try library.views(ids)
    // まだサムネイルの無い画像と動画は、待ち行列の先頭へ入れて最大 8 秒待つ。
    let missing = views.filter { $0.thumb == nil && $0.media != nil }.map(\.id)
    if !missing.isEmpty {
      await pipeline.ready(missing, timeout: 8)
      views = try library.views(ids)
    }
    let byId = Dictionary(views.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let files: [Sheets.Source] = try ids.map { id in
      guard let view = byId[id] else { throw EngineError.notFound("\(id) は手元に無い") }
      if let thumb = view.thumb, let key = thumbKey(thumb) { return .file(paths.thumbFile(key: key)) }
      var lines: [String] = []
      for line in [view.title, view.text].compactMap({ $0 }) where !lines.contains(line) { lines.append(line) }
      return .text(lines.joined(separator: "\n"))
    }
    return try await Imaging.work {
      let cells: [Sheets.Cell] = try files.map { source in
        switch source {
        case let .file(url): .image(try Self.loadImage(url))
        case let .text(text): .text(text)
        }
      }
      return try Imaging.jpeg(try Sheets.contact(cells), quality: 0.85)
    }
  }

  public func frames(id: String, count: Int) async throws -> (jpeg: Data, times: [Int]) {
    let view = try await shot(id)
    guard view.kind == .video, let media = view.media, let src = URL(string: media.src) else { throw EngineError.badRequest("\(id) は動画ではない") }
    let home = try home(of: view.source)
    if Thumbnailer.isHLS(src) {
      // HLS は AVAsset でフレームを取れないので、poster 1 枚を時刻 0 として返す。
      guard let poster = media.poster.flatMap(URL.init(string:)) else { throw EngineError.unavailable("HLS の動画に poster が無い: \(id)") }
      let image = try await fetcher.image(poster, referer: home, maxSide: Sheets.maxSide)
      return (try await Imaging.work { try Imaging.jpeg(try Sheets.strip([image]), quality: 0.85) }, [0])
    }
    let n = min(max(count, 1), 16)
    let frames = try await fetcher.videoFrames(src, referer: home, count: n, maxSide: Sheets.maxSide / n * 2)
    let images = frames.map(\.image)
    return (try await Imaging.work { try Imaging.jpeg(try Sheets.strip(images), quality: 0.85) }, frames.map(\.ms))
  }

  public func view(id: String) async throws -> Data {
    let view = try await shot(id)
    let home = try home(of: view.source)
    let job = MediaJob(id: id, source: view.source, kind: view.kind, media: view.media.map { ShotMedia(src: $0.src, poster: view.kind == .video ? $0.poster : nil, width: $0.width, height: $0.height) }, title: view.title, text: view.text, thumb: nil, thumbAttempts: 0)
    guard let image = try await thumbnailer.still(job, home: home, maxSide: Sheets.maxSide) else {
      throw EngineError.notFound("\(id) は画像を持たない文章の Shot")
    }
    return try await Imaging.work { try Imaging.jpeg(image, quality: 0.85) }
  }

  public func mediaFile(key: String) -> URL? {
    let file: URL
    if let thumb = thumbKey(key) {
      file = paths.thumbFile(key: thumb)
    } else if key.hasPrefix("icon-"), key.hasSuffix(".png") {
      let id = String(key.dropFirst(5).dropLast(4))
      guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
      file = paths.iconFile(source: id)
    } else {
      return nil
    }
    return FileManager.default.fileExists(atPath: file.path) ? file : nil
  }

  public func source(_ id: String) -> SourceFile? {
    files[id]
  }

  // MARK: - 内部

  private func queryVector(_ text: String) async throws -> [Float] {
    guard let embedder else { throw EmbedderError.notConfigured }
    return try await Imaging.work { Ranking.normalized(try embedder.embed(text: text)) }
  }

  private func nearest(_ vector: [Float], sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int) throws -> [(id: String, score: Float)] {
    guard let index else { throw EmbedderError.notConfigured }
    return index.nearest(vector, limit: limit) { id, kind in
      (kinds?.contains(kind) ?? true) && (sources?.contains(String(id.prefix { $0 != ":" })) ?? true)
    }
  }

  /// 種類で絞り、重複をまとめて代表に件数を入れ、必要ならサイトを交互にしてから `limit` 件に切る。
  private func arrange(_ ids: [String], kinds: Set<ShotKind>?, limit: Int, interleave: Bool) throws -> [ShotView] {
    let rows = try library.rows(ids).filter { kinds?.contains($0.view.kind) ?? true }
    let candidates = rows.map { row in
      Ranking.Candidate(
        id: row.view.id,
        source: row.view.source,
        visual: row.view.kind != .text,
        area: (row.view.media?.width ?? 0) * (row.view.media?.height ?? 0),
        fromList: row.via == .list,
        selected: row.view.selected,
        vector: index?.vector(row.view.id)
      )
    }
    let views = Dictionary(rows.map { ($0.view.id, $0.view) }, uniquingKeysWith: { a, _ in a })
    var merged = Ranking.collapse(candidates).map { candidate, count -> ShotView in
      var view = views[candidate.id]!
      view.duplicates = count
      return view
    }
    if interleave { merged = Ranking.interleave(merged, source: \.source) }
    return Array(merged.prefix(limit))
  }

  private func home(of source: String) throws -> URL {
    guard let file = files[source] else { throw EngineError.unavailable("\(source) のサイト用 JS が無い") }
    return file.meta.home
  }

  /// `/media/<sha1>.jpg` か `<sha1>.jpg` から sha1 を取り出す。
  private func thumbKey(_ text: String) -> String? {
    let name = text.hasPrefix("/media/") ? String(text.dropFirst(7)) : text
    guard name.hasSuffix(".jpg") else { return nil }
    let key = String(name.dropLast(4))
    return key.count == 40 && key.allSatisfy(\.isHexDigit) ? key : nil
  }

  private static func loadImage(_ file: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw MediaError.decode(file.path)
    }
    return image
  }
}
