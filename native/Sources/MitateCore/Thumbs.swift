import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaError: Error, CustomStringConvertible {
  case http(Int, String)
  case decode(String)
  case unavailable(String)

  public var description: String {
    switch self {
    case let .http(status, url): "HTTP \(status) \(url)"
    case let .decode(m): "画像を読めない: \(m)"
    case let .unavailable(m): m
    }
  }
}

/// メディアの取得。Cookie は付けず、Safari の User-Agent とサイトの home を Referer に付ける。
public struct MediaFetcher: Sendable {
  private let session: URLSession

  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.httpCookieStorage = nil
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 120
    session = URLSession(configuration: config)
  }

  public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(SourceRunner.safariApplicationName)"

  static func headers(referer: URL) -> [String: String] {
    ["User-Agent": userAgent, "Referer": referer.absoluteString]
  }

  public func data(_ url: URL, referer: URL) async throws -> Data {
    var request = URLRequest(url: url)
    for (name, value) in Self.headers(referer: referer) { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw MediaError.unavailable("HTTP の応答ではない: \(url.absoluteString)") }
    guard (200 ..< 300).contains(http.statusCode) else { throw MediaError.http(http.statusCode, url.absoluteString) }
    return data
  }

  /// 長辺 `maxSide` 以内に縮め、白地に合成した画像。webp・avif・png・gif も読める。
  public func image(_ url: URL, referer: URL, maxSide: Int) async throws -> CGImage {
    let data = try await data(url, referer: referer)
    return try await Imaging.work { try Imaging.decode(data, maxSide: maxSide, label: url.absoluteString) }
  }

  /// 動画の `seconds` 秒のフレーム。動画が短ければ真ん中のフレーム。
  public func videoFrame(_ url: URL, referer: URL, at seconds: Double, maxSide: Int) async throws -> CGImage {
    let asset = Self.asset(url, referer: referer)
    let duration = try await asset.load(.duration).seconds
    let frames = try await Self.frames(asset, at: [min(seconds, duration / 2)], maxSide: maxSide)
    return frames[0]
  }

  /// 動画を等間隔に `count` 枚。各フレームの時刻（ms）を添える。
  public func videoFrames(_ url: URL, referer: URL, count: Int, maxSide: Int) async throws -> [(image: CGImage, ms: Int)] {
    let asset = Self.asset(url, referer: referer)
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0 else { throw MediaError.unavailable("動画の長さを読めない: \(url.absoluteString)") }
    let times = (0 ..< count).map { duration * (Double($0) + 0.5) / Double(count) }
    let images = try await Self.frames(asset, at: times, maxSide: maxSide)
    return zip(images, times).map { ($0, Int(($1 * 1000).rounded())) }
  }

  private static func asset(_ url: URL, referer: URL) -> AVURLAsset {
    // AVURLAsset に Referer を渡す公開の手段が無いので、AVFoundation が読むヘッダーの辞書を使う。
    AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers(referer: referer), AVURLAssetHTTPUserAgentKey: userAgent])
  }

  private static func frames(_ asset: AVURLAsset, at times: [Double], maxSide: Int) async throws -> [CGImage] {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxSide, height: maxSide)
    // 既定の許容幅ではキーフレームへ寄せられ、等間隔に取ったはずのフレームが同じ絵になる。
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var out: [CGImage] = []
    for t in times {
      let frame = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
      out.append(try await Imaging.work { try Imaging.opaque(frame, maxSide: maxSide) })
    }
    return out
  }
}

public struct Thumbnail: Sendable {
  public let key: String
  public let aspect: Double
  public let colors: [String]
}

/// 1 件のサムネイル（長辺 720px の JPEG）と、縦横比、主要色。
public struct Thumbnailer: Sendable {
  public let fetcher: MediaFetcher
  public let paths: Paths
  public static let maxSide = 720

  public init(fetcher: MediaFetcher, paths: Paths) {
    self.fetcher = fetcher
    self.paths = paths
  }

  public static func key(for id: String) -> String {
    Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// サムネイルを作る元の画像が無い（メディアを持たない text）なら nil。
  public func make(_ job: MediaJob, home: URL) async throws -> Thumbnail? {
    guard let image = try await still(job, home: home, maxSide: Self.maxSide) else { return nil }
    let key = Self.key(for: job.id)
    let file = paths.thumbFile(key: key)
    return try await Imaging.work {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Imaging.jpeg(image, quality: 0.82).write(to: file, options: .atomic)
      return Thumbnail(key: key, aspect: Double(image.width) / Double(image.height), colors: try Imaging.dominantColors(image))
    }
  }

  /// image と video は poster、無ければ src。video で poster が無いときは 0.5 秒のフレーム。
  public func still(_ job: MediaJob, home: URL, maxSide: Int) async throws -> CGImage? {
    guard let media = job.media else {
      if job.kind == .text { return nil }
      throw MediaError.unavailable("\(job.id) に media が無い")
    }
    if let poster = media.poster {
      return try await fetcher.image(try url(poster), referer: home, maxSide: maxSide)
    }
    let src = try url(media.src)
    if job.kind == .video {
      if Self.isHLS(src) { throw MediaError.unavailable("HLS の動画に poster が無い: \(media.src)") }
      return try await fetcher.videoFrame(src, referer: home, at: 0.5, maxSide: maxSide)
    }
    return try await fetcher.image(src, referer: home, maxSide: maxSide)
  }

  public static func isHLS(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "m3u8"
  }

  private func url(_ text: String) throws -> URL {
    guard let url = URL(string: text) else { throw MediaError.unavailable("URL として読めない: \(text)") }
    return url
  }

  // MARK: - favicon

  /// home の HTML の `link rel="apple-touch-icon"`・`icon`、無ければ `/favicon.ico` を、64px の PNG にする。
  public func favicon(home: URL) async throws -> Data {
    var candidates: [URL] = []
    var reasons: [String] = []
    do {
      let html = String(decoding: try await fetcher.data(home, referer: home), as: UTF8.self)
      candidates = Self.iconLinks(in: html, base: home)
    } catch {
      reasons.append("home: \(error)")
    }
    if let ico = URL(string: "/favicon.ico", relativeTo: home)?.absoluteURL { candidates.append(ico) }
    for url in candidates {
      do {
        let data = try await fetcher.data(url, referer: home)
        return try await Imaging.work { try Imaging.png(try Imaging.icon(data, side: 64, label: url.absoluteString)) }
      } catch {
        reasons.append("\(url.absoluteString): \(error)")
      }
    }
    throw MediaError.unavailable("favicon を取れない（\(reasons.joined(separator: "; "))）")
  }

  /// 大きいものから順に。SVG は ImageIO で読めないので拡張子で除く。`type` は実際の形式と違うサイトがあるので見ない（読めなければ次の候補へ進む）。
  static func iconLinks(in html: String, base: URL) -> [URL] {
    let tag = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
    let attr = try! NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
    var found: [(url: URL, rank: Int)] = []
    let ns = html as NSString
    for match in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
      let text = ns.substring(with: match.range)
      var attrs: [String: String] = [:]
      for a in attr.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
        let name = (text as NSString).substring(with: a.range(at: 1)).lowercased()
        let value = (2 ... 4).compactMap { a.range(at: $0).location == NSNotFound ? nil : (text as NSString).substring(with: a.range(at: $0)) }.first ?? ""
        attrs[name] = value
      }
      let rel = Set((attrs["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
      guard let href = attrs["href"], !href.lowercased().hasSuffix(".svg"),
            let url = URL(string: href.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL
      else { continue }
      let size = Int((attrs["sizes"] ?? "").lowercased().split(separator: "x").first ?? "") ?? 0
      if rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") {
        found.append((url, 10_000 + size))
      } else if rel.contains("icon") {
        found.append((url, size))
      }
    }
    return found.sorted { $0.rank > $1.rank }.map(\.url)
  }
}

// MARK: - 画像の加工

public enum Imaging {
  static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

  /// 画像の復号・縮小・符号化と埋め込みの計算は、ハードウェアの処理を同期で待つことがあるので、Swift の協調スレッドを塞がないよう専用のキューで回す。
  static let queue = DispatchQueue(label: "mitate.imaging", qos: .utility, attributes: .concurrent)

  public static func work<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try body() }) }
    }
  }

  /// 長辺 `maxSide` 以内のサムネイルを ImageIO で作り、白地に合成する。
  public static func decode(_ data: Data, maxSide: Int, label: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
      throw MediaError.decode(label)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxSide,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw MediaError.decode(label) }
    return try opaque(image, maxSide: maxSide)
  }

  /// 透過を白で埋め、長辺 `maxSide` 以内の sRGB にする。拡大はしない。
  public static func opaque(_ image: CGImage, maxSide: Int) throws -> CGImage {
    let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
    let w = max(1, Int((Double(image.width) * scale).rounded()))
    let h = max(1, Int((Double(image.height) * scale).rounded()))
    let ctx = try context(width: w, height: h, alpha: false)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let out = ctx.makeImage() else { throw MediaError.decode("描画に失敗") }
    return out
  }

  /// 正方形 `side` px に収めた透過の画像。ICO などは最も大きい画像を選ぶ。
  static func icon(_ data: Data, side: Int, label: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw MediaError.decode(label) }
    let largest = (0 ..< CGImageSourceGetCount(source)).max { a, b in
      pixelWidth(source, a) < pixelWidth(source, b)
    }!
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, largest, options as CFDictionary) else { throw MediaError.decode(label) }
    let ctx = try context(width: side, height: side, alpha: true)
    let scale = Double(side) / Double(max(image.width, image.height))
    let w = Double(image.width) * scale, h = Double(image.height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
    guard let out = ctx.makeImage() else { throw MediaError.decode(label) }
    return out
  }

  private static func pixelWidth(_ source: CGImageSource, _ index: Int) -> Int {
    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    return props?[kCGImagePropertyPixelWidth] as? Int ?? 0
  }

  static func context(width: Int, height: Int, alpha: Bool) throws -> CGContext {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info) else {
      throw MediaError.decode("\(width)x\(height) の描画面を作れない")
    }
    return ctx
  }

  public static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
    try encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
  }

  public static func png(_ image: CGImage) throws -> Data {
    try encode(image, type: .png, properties: [:])
  }

  private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw MediaError.decode("\(type.identifier) を書けない") }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw MediaError.decode("\(type.identifier) の書き出しに失敗") }
    return data as Data
  }

  /// 32×32 に縮めた画素を k-means（k=5）でまとめ、多い順の `#rrggbb`。
  public static func dominantColors(_ image: CGImage, k: Int = 5) throws -> [String] {
    let side = 32
    let ctx = try context(width: side, height: side, alpha: false)
    guard let data = ctx.data else { throw MediaError.decode("主要色の描画面に画素が無い") }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * side)
    var pixels: [SIMD3<Float>] = []
    for y in 0 ..< side {
      for x in 0 ..< side {
        let p = y * ctx.bytesPerRow + x * 4
        pixels.append(SIMD3(Float(bytes[p]), Float(bytes[p + 1]), Float(bytes[p + 2])))
      }
    }
    return kMeans(pixels, k: k).map { c in
      String(format: "#%02x%02x%02x", Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }
  }

  /// 中心は平均色から始め、既存の中心から最も遠い画素を足していく。空になった群は捨て、大きい群から返す。
  static func kMeans(_ pixels: [SIMD3<Float>], k: Int, iterations: Int = 12) -> [SIMD3<Float>] {
    guard !pixels.isEmpty else { return [] }
    func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = a - b; return (d * d).sum() }
    var centers = [pixels.reduce(SIMD3<Float>(), +) / Float(pixels.count)]
    while centers.count < k {
      let far = pixels.max { a, b in centers.map { distance($0, a) }.min()! < centers.map { distance($0, b) }.min()! }!
      if centers.contains(far) { break }
      centers.append(far)
    }
    var assignment = [Int](repeating: 0, count: pixels.count)
    for _ in 0 ..< iterations {
      for (i, p) in pixels.enumerated() {
        assignment[i] = centers.indices.min { distance(centers[$0], p) < distance(centers[$1], p) }!
      }
      var sums = [SIMD3<Float>](repeating: SIMD3(), count: centers.count)
      var counts = [Int](repeating: 0, count: centers.count)
      for (i, p) in pixels.enumerated() {
        sums[assignment[i]] += p
        counts[assignment[i]] += 1
      }
      for c in centers.indices where counts[c] > 0 { centers[c] = sums[c] / Float(counts[c]) }
    }
    var counts = [Int](repeating: 0, count: centers.count)
    for a in assignment { counts[a] += 1 }
    return centers.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }.map { centers[$0] }
  }
}
