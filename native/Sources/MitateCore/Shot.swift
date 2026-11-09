import Foundation

public enum ShotKind: String, Codable, Sendable, CaseIterable {
  case image, video, text
}

public struct ShotMedia: Codable, Hashable, Sendable {
  public var src: String
  public var poster: String?
  public var width: Double?
  public var height: Double?
}

/// サイトから取った 1 件。id は `<source>:<サイト側の id>` で、何度取っても同じになる。
public struct Shot: Codable, Hashable, Sendable {
  public var id: String
  public var source: String
  public var url: String
  /// 集約サイトが引用している原典（X の投稿、画像の掲載元など）
  public var origin: String?
  public var kind: ShotKind
  public var media: ShotMedia?
  public var title: String?
  public var text: String?
  public var tags: [String]
  public var author: String?
  public var publishedAt: String?
}

/// サイト用 JS が返す 1 件。検証を通ったものだけが Shot になる。
struct RawShot: Decodable {
  var id: String?
  var url: String?
  var origin: String?
  var kind: String?
  var media: ShotMedia?
  var title: String?
  var text: String?
  var tags: [String]?
  var author: String?
  var publishedAt: String?
}

public struct ShotError: Error, CustomStringConvertible, Sendable {
  public let index: Int
  public let reason: String
  public var description: String { "#\(index): \(reason)" }
}

extension RawShot {
  func validated(source: String, index: Int) -> Result<Shot, ShotError> {
    func fail(_ reason: String) -> Result<Shot, ShotError> { .failure(ShotError(index: index, reason: reason)) }
    guard let nativeId = id?.trimmingCharacters(in: .whitespaces), !nativeId.isEmpty else { return fail("id が無い") }
    guard let url, isHTTP(url) else { return fail("url が http(s) の絶対 URL ではない: \(url ?? "nil")") }
    if let origin, !isHTTP(origin) { return fail("origin が http(s) の絶対 URL ではない: \(origin)") }
    guard let kindName = kind, let kind = ShotKind(rawValue: kindName) else { return fail("kind が image・video・text のどれでもない: \(kind ?? "nil")") }
    switch kind {
    case .image, .video:
      guard let media, isHTTP(media.src) else { return fail("\(kind.rawValue) に media.src が無い") }
      if let poster = media.poster, !isHTTP(poster) { return fail("media.poster が絶対 URL ではない: \(poster)") }
    case .text:
      guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return fail("text の Shot に text が無い") }
      if let media, !isHTTP(media.src) { return fail("media.src が絶対 URL ではない: \(media.src)") }
    }
    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return .success(Shot(
      id: "\(source):\(nativeId)",
      source: source,
      url: url,
      origin: origin,
      kind: kind,
      media: media,
      title: cleanTitle?.isEmpty == true ? nil : cleanTitle,
      text: text?.trimmingCharacters(in: .whitespacesAndNewlines),
      tags: (tags ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
      author: author,
      publishedAt: publishedAt
    ))
  }
}

func isHTTP(_ s: String?) -> Bool {
  guard let s, let u = URL(string: s), let scheme = u.scheme?.lowercased(), u.host != nil else { return false }
  return scheme == "https" || scheme == "http"
}
