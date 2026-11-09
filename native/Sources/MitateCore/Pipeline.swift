import CoreGraphics
import Foundation
import ImageIO

/// 保存した Shot のサムネイルを取り、続けて埋め込みを計算する待ち行列。
/// 急ぐもの（live 検索の結果）は列の先頭に入れる。
public actor Pipeline {
  private let library: Library
  private let thumbnailer: Thumbnailer
  private let embedder: Embedder?
  private let index: VectorIndex?
  private let homes: [String: URL]

  private var thumbUrgent: [String] = []
  private var thumbBacklog: [String] = []
  private var embedUrgent: [String] = []
  private var embedBacklog: [String] = []
  private var urgent: Set<String> = []
  /// どちらかの段に並んでいるか、処理中のもの
  private var pending: Set<String> = []
  /// この起動中にサムネイルを試したもの。失敗は起動ごとに 1 回だけ取り直す
  private var tried: Set<String> = []
  private var thumbRunning = 0
  private var embedRunning = 0
  private(set) var thumbFailures = 0
  private(set) var embedFailures = 0

  static let thumbLimit = 6
  static let embedLimit = 2

  public init(library: Library, thumbnailer: Thumbnailer, embedder: Embedder?, index: VectorIndex?, homes: [String: URL]) {
    self.library = library
    self.thumbnailer = thumbnailer
    self.embedder = embedder
    self.index = index
    self.homes = homes
  }

  /// 手元にあってまだ計算していないものを、新しい順に並べる。
  public func start() throws {
    let thumbs = try library.pendingThumbs()
    let embeds = try embedder.map { try library.pendingEmbeds(model: $0.model) } ?? []
    let inThumbs = Set(thumbs)
    thumbBacklog = thumbs
    embedBacklog = embeds.filter { !inThumbs.contains($0) }
    pending = inThumbs.union(embedBacklog)
    log("pipeline: サムネイル \(thumbBacklog.count) 件、埋め込み \(embedBacklog.count) 件を待ち行列へ")
    pump()
  }

  public func enqueue(_ ids: [String], urgent isUrgent: Bool = false) {
    for id in ids {
      if pending.contains(id) {
        guard isUrgent, !urgent.contains(id) else { continue }
        urgent.insert(id)
        if let i = thumbBacklog.firstIndex(of: id) {
          thumbBacklog.remove(at: i)
          thumbUrgent.append(id)
        } else if let i = embedBacklog.firstIndex(of: id) {
          embedBacklog.remove(at: i)
          embedUrgent.append(id)
        }
        continue
      }
      pending.insert(id)
      if isUrgent {
        urgent.insert(id)
        thumbUrgent.append(id)
      } else {
        thumbBacklog.append(id)
      }
    }
    pump()
  }

  /// `ids` を先頭に入れ、すべて終わるか `timeout` 秒たつまで待つ。
  public func ready(_ ids: [String], timeout: TimeInterval) async {
    enqueue(ids, urgent: true)
    let deadline = Date().addingTimeInterval(timeout)
    while ids.contains(where: pending.contains), Date() < deadline {
      do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
    }
  }

  private func pump() {
    while thumbRunning < Self.thumbLimit, let id = pop(&thumbUrgent, &thumbBacklog) {
      thumbRunning += 1
      Task { await self.thumb(id) }
    }
    while embedRunning < Self.embedLimit, let id = pop(&embedUrgent, &embedBacklog) {
      embedRunning += 1
      Task { await self.embed(id) }
    }
  }

  private func pop(_ first: inout [String], _ second: inout [String]) -> String? {
    if !first.isEmpty { return first.removeFirst() }
    if !second.isEmpty { return second.removeFirst() }
    return nil
  }

  private func thumb(_ id: String) async {
    defer {
      thumbRunning -= 1
      pump()
    }
    do {
      guard let job = try library.mediaJob(id) else { return finish(id) }
      if job.thumb == nil, job.media != nil, job.thumbAttempts < 3, !tried.contains(id) {
        tried.insert(id)
        guard let home = homes[job.source] else { throw MediaError.unavailable("\(job.source) のサイト用 JS が無い") }
        var lastError: Error?
        for _ in 0 ..< 2 {
          do {
            if let made = try await thumbnailer.make(job, home: home) {
              try library.setThumb(id, key: made.key, aspect: made.aspect, colors: made.colors)
            }
            lastError = nil
            break
          } catch {
            lastError = error
          }
        }
        if let lastError {
          thumbFailures += 1
          try library.thumbFailed(id, error: "\(lastError)")
          log("thumb: 失敗 \(thumbFailures) 件目 \(id): \(lastError)")
        }
      }
    } catch {
      thumbFailures += 1
      log("thumb: 失敗 \(thumbFailures) 件目 \(id): \(error)")
    }
    guard embedder != nil else { return finish(id) }
    if urgent.contains(id) { embedUrgent.append(id) } else { embedBacklog.append(id) }
  }

  private func embed(_ id: String) async {
    defer {
      embedRunning -= 1
      finish(id)
      pump()
    }
    guard let embedder, let index, index.vector(id) == nil else { return }
    do {
      guard let job = try library.mediaJob(id), let vector = try await Self.vector(job, embedder: embedder, thumbs: thumbnailer.paths) else { return }
      try library.setVector(id, model: embedder.model, vector: vector)
      index.set(id, kind: job.kind, vector)
    } catch {
      embedFailures += 1
      log("embed: 失敗 \(embedFailures) 件目 \(id): \(error)")
    }
  }

  /// サムネイルがあれば画像から、サムネイルの無い text は `title + text` から。どちらも無ければ nil。
  nonisolated static func vector(_ job: MediaJob, embedder: Embedder, thumbs: Paths) async throws -> [Float]? {
    if let key = job.thumb {
      let file = thumbs.thumbFile(key: key)
      return try await Imaging.work {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
          throw MediaError.decode(file.path)
        }
        return Ranking.normalized(try embedder.embed(image: image))
      }
    }
    guard job.kind == .text else { return nil }
    let text = [job.title, job.text].compactMap { $0 }.joined(separator: "\n")
    guard !text.isEmpty else { return nil }
    return try await Imaging.work { Ranking.normalized(try embedder.embed(text: text)) }
  }

  private func finish(_ id: String) {
    pending.remove(id)
    urgent.remove(id)
  }
}

/// 標準エラーへ 1 行。標準出力は MCP と CLI の出力に使う。
public func log(_ message: String) {
  FileHandle.standardError.write(Data("[mitate] \(message)\n".utf8))
}
