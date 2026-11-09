import CoreGraphics
import CoreText
import Foundation

/// AI に見せる画像。番号付きのコンタクトシートと、動画のフレーム列。
public enum Sheets {
  public static let maxSide = 1568
  /// 1 枚のコンタクトシートに並べる上限。これより多いとセルが小さすぎて見分けられない
  public static let maxCount = 64

  public enum Cell {
    case image(CGImage)
    /// サムネイルの無い文章の Shot
    case text(String)
  }

  /// 読み込む前のセル。
  public enum Source: Sendable {
    case file(URL)
    case text(String)
  }

  /// 列数は `ceil(sqrt(n))`。各セルの左上に 1 からの番号を描く。
  public static func contact(_ cells: [Cell]) throws -> CGImage {
    guard !cells.isEmpty else { throw MediaError.unavailable("コンタクトシートに並べるものが無い") }
    let cols = Int(Double(cells.count).squareRoot().rounded(.up))
    let rows = (cells.count + cols - 1) / cols
    let gap = 6
    let cell = min(520, (maxSide - gap * (max(cols, rows) + 1)) / max(cols, rows))
    let width = cols * cell + (cols + 1) * gap
    let height = rows * cell + (rows + 1) * gap
    let ctx = try Imaging.context(width: width, height: height, alpha: false)
    ctx.setFillColor(gray(0.11))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    let labelSize = max(14, CGFloat(cell) * 0.08)
    for (i, item) in cells.enumerated() {
      let col = i % cols, row = i / cols
      let rect = CGRect(x: gap + col * (cell + gap), y: height - (row + 1) * (cell + gap), width: cell, height: cell)
      switch item {
      case let .image(image):
        ctx.setFillColor(gray(0.18))
        ctx.fill(rect)
        ctx.draw(image, in: fit(CGSize(width: image.width, height: image.height), in: rect))
      case let .text(text):
        ctx.setFillColor(gray(0.95))
        ctx.fill(rect)
        // 文章は左上の番号の下から書く。
        let inset = CGFloat(cell) * 0.08
        let body = CGRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - inset * 2, height: rect.height - inset * 2 - labelSize * 2)
        paragraph(text, in: body, size: max(12, CGFloat(cell) * 0.07), ctx: ctx)
      }
      label("\(i + 1)", at: CGPoint(x: rect.minX, y: rect.maxY), size: labelSize, ctx: ctx)
    }
    guard let image = ctx.makeImage() else { throw MediaError.decode("コンタクトシートの描画に失敗") }
    return image
  }

  /// フレームを横に並べる。全体の幅は `maxSide` 以内。
  public static func strip(_ frames: [CGImage]) throws -> CGImage {
    guard !frames.isEmpty else { throw MediaError.unavailable("並べるフレームが無い") }
    let gap = 4
    let aspects = frames.map { Double($0.width) / Double($0.height) }
    let usable = Double(maxSide - gap * (frames.count + 1))
    let frameHeight = min(Double(maxSide) / 2, usable / aspects.reduce(0, +)).rounded(.down)
    let widths = aspects.map { Int(($0 * frameHeight).rounded(.down)) }
    let width = widths.reduce(0, +) + gap * (frames.count + 1)
    let height = Int(frameHeight) + gap * 2
    let ctx = try Imaging.context(width: width, height: height, alpha: false)
    ctx.setFillColor(gray(0.11))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    var x = gap
    for (i, frame) in frames.enumerated() {
      let rect = CGRect(x: x, y: gap, width: widths[i], height: Int(frameHeight))
      ctx.draw(frame, in: rect)
      label("\(i + 1)", at: CGPoint(x: rect.minX, y: rect.maxY), size: max(12, frameHeight * 0.1), ctx: ctx)
      x += widths[i] + gap
    }
    guard let image = ctx.makeImage() else { throw MediaError.decode("フレーム列の描画に失敗") }
    return image
  }

  private static func gray(_ v: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: v, green: v, blue: v, alpha: alpha)
  }

  private static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
    let scale = min(rect.width / size.width, rect.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
  }

  /// 左上の角に、暗い角丸の地に白抜きの番号。
  private static func label(_ text: String, at topLeft: CGPoint, size: CGFloat, ctx: CGContext) {
    let line = CTLineCreateWithAttributedString(attributed(text, size: size, font: .emphasizedSystem, color: gray(1)))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let pad = size * 0.35
    let box = CGRect(x: topLeft.x, y: topLeft.y - bounds.height - pad * 2, width: max(bounds.width + pad * 2, bounds.height + pad * 2), height: bounds.height + pad * 2)
    ctx.setFillColor(gray(0, alpha: 0.78))
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: pad, cornerHeight: pad, transform: nil))
    ctx.fillPath()
    ctx.textPosition = CGPoint(x: box.midX - bounds.width / 2 - bounds.minX, y: box.minY + pad - bounds.minY)
    CTLineDraw(line, ctx)
  }

  private static func paragraph(_ text: String, in rect: CGRect, size: CGFloat, ctx: CGContext) {
    let setter = CTFramesetterCreateWithAttributedString(attributed(text, size: size, font: .system, color: gray(0.1)))
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
  }

  private static func attributed(_ text: String, size: CGFloat, font type: CTFontUIFontType, color: CGColor) -> CFAttributedString {
    let font = CTFontCreateUIFontForLanguage(type, size, nil)!
    return NSAttributedString(string: text, attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
  }
}
