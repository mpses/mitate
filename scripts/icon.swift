import AppKit
import CoreGraphics

// usage: swift icon.swift <背景 #rrggbb> <タイル #rrggbb> <選んだタイル #rrggbb> <out.png>
let args = CommandLine.arguments.dropFirst().map { $0 }
guard args.count == 4 else {
  FileHandle.standardError.write("usage: icon.swift <bg> <tile> <picked> <out.png>\n".data(using: .utf8)!)
  exit(64)
}

func color(_ hex: String) -> CGColor {
  let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
  guard h.count == 6, let v = UInt32(h, radix: 16) else {
    FileHandle.standardError.write("不正な色: \(hex)\n".data(using: .utf8)!)
    exit(64)
  }
  return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

/// macOS のアイコンの外形に合わせた superellipse。
func squircle(_ rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
  let path = CGMutablePath()
  let a = rect.width / 2, b = rect.height / 2
  let steps = 720
  for i in 0 ... steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let c = cos(t), s = sin(t)
    let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
    let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
  }
  path.closeSubpath()
  return path
}

let size = 1024
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Apple のテンプレートどおり、1024 の画布に 824 の本体を置く。
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(squircle(body))
ctx.setFillColor(color(args[0]))
ctx.fillPath()

// 2 列のマソンリーを本体の中心に置く。CoreGraphics は上が y の大きい側。
let gap: CGFloat = 40
let group = body.width * 0.58
let columnWidth = (group - gap) / 2
let left = body.midX - group / 2, right = left + columnWidth + gap
let top = body.midY + group / 2, bottom = body.midY - group / 2
let height = group
let radius: CGFloat = 44
let tiles: [(CGRect, Bool)] = [
  (CGRect(x: left, y: top - height * 0.62, width: columnWidth, height: height * 0.62), false),
  (CGRect(x: left, y: bottom, width: columnWidth, height: height * 0.38 - gap), false),
  (CGRect(x: right, y: top - height * 0.36, width: columnWidth, height: height * 0.36), true),
  (CGRect(x: right, y: bottom, width: columnWidth, height: height * 0.64 - gap), false),
]
for (rect, picked) in tiles {
  ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
  ctx.setFillColor(color(picked ? args[2] : args[1]))
  ctx.fillPath()
}

guard let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
do {
  try png.write(to: URL(fileURLWithPath: args[3]))
} catch {
  FileHandle.standardError.write("書き込めない: \(error)\n".data(using: .utf8)!)
  exit(1)
}
