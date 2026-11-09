import Foundation

/// ビューワーからほかのアプリ（エージェントのチャット、端末、Finder）へドラッグで渡すファイル。
/// 受け手はドロップした時点でファイルを読むので、ドラッグを始める前に書き終える。
public struct DragOut: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  /// 一時ディレクトリの下に置く。使われなくなったファイルは OS が片付ける。
  public static func temporary() -> DragOut {
    DragOut(root: FileManager.default.temporaryDirectory.appendingPathComponent("Mitate/drag", isDirectory: true))
  }

  public struct Written: Sendable {
    public var files: [(view: ShotView, file: URL)] = []
    /// サムネイルをまだ取っていないので渡せなかった Shot
    public var missing: [String] = []
  }

  /// Shot を 1 件 1 ファイルにする。画像と動画は手元のサムネイル（動画は poster）、文章は Markdown。
  /// `thumb` は ShotView.thumb を手元のファイルに引く。
  public func write(_ views: [ShotView], thumb: (String) -> URL?) throws -> Written {
    let fm = FileManager.default
    var written = Written()
    for view in views {
      let file = try self.file(for: view)
      switch view.kind {
      case .text:
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.markdown(view).utf8).write(to: file, options: .atomic)
      case .image, .video:
        guard let key = view.thumb, let source = thumb(key) else {
          written.missing.append(view.id)
          continue
        }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try fm.copyItem(at: source, to: file)
      }
      written.files.append((view, file))
    }
    return written
  }

  /// `<サイト>/<サイト側の id>.jpg`（文章は `.md`）。id の記号は % で写すので、パスから Shot の id に戻せる。
  public func file(for view: ShotView) throws -> URL {
    let prefix = "\(view.source):"
    guard view.id.hasPrefix(prefix) else { throw DragOutError("\(view.id) が \(prefix) で始まらない") }
    var name = String(view.id.dropFirst(prefix.count)).addingPercentEncoding(withAllowedCharacters: Self.plain) ?? ""
    // 先頭の . は隠しファイルになる。長すぎる名前はファイルシステムが受けないので、id のハッシュにする
    if name.hasPrefix(".") { name = "%2E" + name.dropFirst() }
    if name.isEmpty || name.utf8.count > 200 { name = Thumbnailer.key(for: view.id) }
    return root
      .appendingPathComponent(view.source, isDirectory: true)
      .appendingPathComponent(name)
      .appendingPathExtension(view.kind == .text ? "md" : "jpg")
  }

  private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

  /// 見出し、出典、本文の順。
  static func markdown(_ view: ShotView) -> String {
    var blocks: [String] = []
    if let title = view.title { blocks.append("# \(title)") }
    blocks.append(view.url)
    if let origin = view.origin { blocks.append(origin) }
    if let text = view.text { blocks.append(text) }
    return blocks.joined(separator: "\n\n") + "\n"
  }
}

public struct DragOutError: Error, CustomStringConvertible, Sendable {
  public let description: String
  init(_ description: String) {
    self.description = description
  }
}
