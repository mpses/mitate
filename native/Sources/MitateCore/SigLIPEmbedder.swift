import Accelerate
import CoreGraphics
import Foundation
import OnnxRuntimeBindings

public enum SigLIPError: Error, CustomStringConvertible {
  case missing(directory: String, files: [String])
  case ambiguous(directory: String, files: [String])
  case config(String)
  case model(file: String, reason: String)
  case onnx(String, Error)
  case output(String)

  public var description: String {
    switch self {
    case let .missing(dir, files): "\(dir) に \(files.joined(separator: "、")) が無い"
    case let .ambiguous(dir, files): "\(dir) に候補が複数ある: \(files.joined(separator: "、"))"
    case let .config(m): "モデルの設定が読めない: \(m)"
    case let .model(file, reason): "\(file) を ONNX のモデルとして読めない: \(reason)"
    case let .onnx(what, error): "ONNX Runtime の\(what)に失敗: \(error.localizedDescription)"
    case let .output(m): "モデルの出力が想定と違う: \(m)"
    }
  }
}

/// vision と text の ONNX Runtime の session は使う時だけ作り、しばらく使わなければ放す
public final class SigLIPEmbedder: Embedder, @unchecked Sendable {
  public enum ExecutionProvider: Sendable {
    case cpu
    case coreML
  }

  /// 放した後の最初の検索には text の session を作り直す 0.3 秒ほどが足されるが、持ち続けると 560MB を使い続ける
  public static let idleSeconds: TimeInterval = 60

  public let model: String
  public let dimension: Int
  private let vision: IdleSession
  private let text: IdleSession
  private let tokenizer: GemmaTokenizer
  private let width: Int
  private let height: Int
  private let scale: [Float]
  private let offset: [Float]

  /// CPU で動かす。M2 Pro の実測で CoreML の execution provider は速くならず、fp32 では読み込みに 50 秒かかった
  public convenience init(directory: URL) throws {
    try self.init(directory: directory, executionProvider: .cpu, idleSeconds: Self.idleSeconds)
  }

  public init(directory: URL, executionProvider: ExecutionProvider, idleSeconds: TimeInterval) throws {
    let fm = FileManager.default
    let onnxDir = directory.appendingPathComponent("onnx", isDirectory: true)
    let onnxFiles = fm.fileExists(atPath: onnxDir.path) ? try fm.contentsOfDirectory(atPath: onnxDir.path).filter { $0.hasSuffix(".onnx") }.sorted() : []
    var missing = ["config.json", "tokenizer.json", "preprocessor_config.json"].filter {
      !fm.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
    var variants: [String: (file: String, variant: String)] = [:]
    for kind in ["vision", "text"] {
      let candidates = onnxFiles.filter { $0 == "\(kind)_model.onnx" || $0.hasPrefix("\(kind)_model_") }
      switch candidates.count {
      case 0: missing.append("onnx/\(kind)_model*.onnx")
      case 1:
        let suffix = candidates[0].dropFirst("\(kind)_model".count).dropLast(".onnx".count)
        variants[kind] = (candidates[0], suffix.isEmpty ? "fp32" : String(suffix.dropFirst()))
      default: throw SigLIPError.ambiguous(directory: onnxDir.path, files: candidates)
      }
    }
    guard missing.isEmpty, let visionFile = variants["vision"], let textFile = variants["text"] else {
      throw SigLIPError.missing(directory: directory.path, files: missing)
    }
    let visionPath = onnxDir.appendingPathComponent(visionFile.file)
    let textPath = onnxDir.appendingPathComponent(textFile.file)

    let config = try Self.readObject(directory.appendingPathComponent("config.json"))
    guard let name = config["_name_or_path"] as? String, let base = name.split(separator: "/").last else {
      throw SigLIPError.config("config.json に _name_or_path が無い")
    }
    model = "\(base)/vision-\(visionFile.variant)+text-\(textFile.variant)"

    let pre = try Self.readObject(directory.appendingPathComponent("preprocessor_config.json"))
    guard pre["do_resize"] as? Bool == true, pre["do_rescale"] as? Bool == true, pre["do_normalize"] as? Bool == true else {
      throw SigLIPError.config("preprocessor_config.json の do_resize・do_rescale・do_normalize がすべて true であること")
    }
    guard let size = pre["size"] as? [String: Any], let w = size["width"] as? Int, let h = size["height"] as? Int, w > 0, h > 0,
          let rescale = (pre["rescale_factor"] as? NSNumber)?.floatValue,
          let mean = (pre["image_mean"] as? [NSNumber])?.map(\.floatValue), let std = (pre["image_std"] as? [NSNumber])?.map(\.floatValue),
          mean.count == 3, std.count == 3, !std.contains(0)
    else {
      throw SigLIPError.config("preprocessor_config.json の size・rescale_factor・image_mean・image_std")
    }
    width = w
    height = h
    scale = (0 ..< 3).map { rescale / std[$0] }
    offset = (0 ..< 3).map { -mean[$0] / std[$0] }

    tokenizer = try GemmaTokenizer(file: directory.appendingPathComponent("tokenizer.json"))

    // session を作らずに、モデルが宣言する出力の形から次元を読む
    let visionDimension = try ONNXModelFile.outputWidth(visionPath, output: "pooler_output")
    let textDimension = try ONNXModelFile.outputWidth(textPath, output: "pooler_output")
    guard textDimension == visionDimension else {
      throw SigLIPError.output("vision の次元 \(visionDimension) と text の次元 \(textDimension) が違う")
    }
    dimension = textDimension

    let env: ORTEnv
    do {
      env = try ORTEnv(loggingLevel: .warning)
    } catch {
      throw SigLIPError.onnx("環境の作成", error)
    }
    // 埋め込みの待ち行列は 2 件を並べて呼ぶ。推論を 1 件ずつ通して中間の値（300MB）を 1 件分に抑え、スレッドを 2 件分にして速さを保つ
    vision = try IdleSession(env: env, path: visionPath.path, options: Self.options(threads: 8, executionProvider), idle: idleSeconds)
    text = try IdleSession(env: env, path: textPath.path, options: Self.options(threads: 4, executionProvider), idle: idleSeconds)
  }

  /// 試験で、使っていない間に session を持っていないことを確かめる
  var loaded: (vision: Bool, text: Bool) {
    (vision.isLoaded, text.isLoaded)
  }

  public func embed(image: CGImage) throws -> [Float] {
    let value = try Self.pixels(image, width: width, height: height, scale: scale, offset: offset)
    return try Self.normalized(vision.run(input: "pixel_values", value: value), expected: dimension)
  }

  /// SigLIP 2 は小文字にした文章で学習している
  public func embed(text input: String) throws -> [Float] {
    try Self.normalized(text.run(input: "input_ids", value: Self.ids(tokenizer.encode(Self.lowercased(input)))), expected: dimension)
  }

  private static func options(threads: Int32, _ executionProvider: ExecutionProvider) throws -> ORTSessionOptions {
    do {
      let options = try ORTSessionOptions()
      try options.setIntraOpNumThreads(threads)
      // 既定の spin 待ちは、ほかの処理と CPU を取り合うときに 1 回の推論を何倍にも遅くする
      try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
      // 1.24.2 の最上位の最適化は fp16 のモデルで SimplifiedLayerNormFusion が失敗し、読み込めない
      try options.setGraphOptimizationLevel(.extended)
      if executionProvider == .coreML {
        // MLProgram 形式は vision の Conv（patch embedding）の変換に失敗する
        try options.appendCoreMLExecutionProvider(withOptionsV2: ["MLComputeUnits": "ALL", "ModelFormat": "NeuralNetwork"])
      }
      return options
    } catch {
      throw SigLIPError.onnx("セッションの設定", error)
    }
  }

  /// Python の `str.lower()` と同じ小文字化。`String.lowercased()` は語末のシグマを ς にしない
  static func lowercased(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (i, s) in scalars.enumerated() {
      if s == "\u{03A3}", isFinalSigma(scalars, at: i) {
        out.append("\u{03C2}")
      } else {
        out.append(contentsOf: s.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return String(out)
  }

  private static func isFinalSigma(_ scalars: [Unicode.Scalar], at i: Int) -> Bool {
    guard let before = scalars[..<i].last(where: { !$0.properties.isCaseIgnorable }), before.properties.isCased else { return false }
    guard let after = scalars[(i + 1)...].first(where: { !$0.properties.isCaseIgnorable }) else { return true }
    return !after.properties.isCased
  }

  private static func readObject(_ file: URL) throws -> [String: Any] {
    do {
      guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        throw SigLIPError.config("\(file.lastPathComponent) がオブジェクトでない")
      }
      return object
    } catch let error as SigLIPError {
      throw error
    } catch {
      throw SigLIPError.config("\(file.lastPathComponent): \(error.localizedDescription)")
    }
  }

  private static func ids(_ ids: [Int32]) throws -> ORTValue {
    let data = NSMutableData(length: ids.count * MemoryLayout<Int64>.stride)!
    let p = data.mutableBytes.assumingMemoryBound(to: Int64.self)
    for (i, id) in ids.enumerated() { p[i] = Int64(id) }
    do {
      return try ORTValue(tensorData: data, elementType: .int64, shape: [1, NSNumber(value: ids.count)])
    } catch {
      throw SigLIPError.onnx("入力の作成", error)
    }
  }

  static func pixels(_ image: CGImage, width: Int, height: Int, scale: [Float], offset: [Float]) throws -> ORTValue {
    let w = image.width
    let h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw SigLIPError.output("\(w)×\(h) の描画先を作れない")
    }
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(rect)
    ctx.draw(image, in: rect)
    guard let rgba = ctx.data?.assumingMemoryBound(to: UInt8.self) else { throw SigLIPError.output("描画先のメモリが無い") }
    let resized = Resampler.bilinear(rgba, width: w, height: h, toWidth: width, toHeight: height)
    let plane = width * height
    let data = NSMutableData(length: 3 * plane * MemoryLayout<Float>.stride)!
    let out = data.mutableBytes.assumingMemoryBound(to: Float.self)
    resized.withUnsafeBufferPointer { px in
      for c in 0 ..< 3 {
        var s = scale[c]
        var o = offset[c]
        vDSP_vfltu8(px.baseAddress! + c, 3, out + c * plane, 1, vDSP_Length(plane))
        vDSP_vsmsa(out + c * plane, 1, &s, &o, out + c * plane, 1, vDSP_Length(plane))
      }
    }
    do {
      return try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, NSNumber(value: height), NSNumber(value: width)])
    } catch {
      throw SigLIPError.onnx("入力の作成", error)
    }
  }

  private static func normalized(_ v: [Float], expected: Int) throws -> [Float] {
    guard v.count == expected else { throw SigLIPError.output("次元 \(v.count)（\(expected) のはず）") }
    var norm: Float = 0
    vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
    norm = norm.squareRoot()
    guard norm > 0, norm.isFinite else { throw SigLIPError.output("ノルムが \(norm)") }
    return vDSP.divide(v, norm)
  }
}

/// 1 つのモデルの session。推論は 1 件ずつ通し、最後の推論から `idle` 秒たったら放して、次の呼び出しで作り直す
private final class IdleSession: @unchecked Sendable {
  private let lock = NSLock()
  private let env: ORTEnv
  private let path: String
  private let options: ORTSessionOptions
  private let idle: TimeInterval
  /// 推論の後に、使っていない arena の領域を OS へ返す
  private let shrink: ORTRunOptions
  private var session: ORTSession?
  private var lastUse = DispatchTime.now()
  private var expiryScheduled = false

  init(env: ORTEnv, path: String, options: ORTSessionOptions, idle: TimeInterval) throws {
    self.env = env
    self.path = path
    self.options = options
    self.idle = idle
    do {
      shrink = try ORTRunOptions()
      try shrink.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
    } catch {
      throw SigLIPError.onnx("推論の設定", error)
    }
  }

  var isLoaded: Bool {
    lock.withLock { session != nil }
  }

  func run(input: String, value: ORTValue) throws -> [Float] {
    lock.lock()
    defer { lock.unlock() }
    let current: ORTSession
    if let session {
      current = session
    } else {
      do {
        current = try ORTSession(env: env, modelPath: path, sessionOptions: options)
      } catch {
        throw SigLIPError.onnx("モデルの読み込み", error)
      }
      session = current
    }
    defer {
      lastUse = .now()
      scheduleExpiry()
    }
    // 中間の値（vision・text とも約 300MB）は推論のたびに返す。持つと、次の呼び出しが来なくても session を放すまで残る。返すと 1 回あたり約 25ms 遅くなる
    return try autoreleasepool { try Self.pooled(current, input: input, value: value, options: shrink) }
  }

  /// lock を持って呼ぶ
  private func scheduleExpiry() {
    guard !expiryScheduled else { return }
    expiryScheduled = true
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: lastUse + idle) { [weak self] in self?.expire() }
  }

  private func expire() {
    lock.lock()
    defer { lock.unlock() }
    expiryScheduled = false
    guard session != nil else { return }
    guard DispatchTime.now() >= lastUse + idle else { return scheduleExpiry() }
    session = nil
  }

  private static func pooled(_ session: ORTSession, input: String, value: ORTValue, options: ORTRunOptions) throws -> [Float] {
    let outputs: [String: ORTValue]
    do {
      outputs = try session.run(withInputs: [input: value], outputNames: ["pooler_output"], runOptions: options)
    } catch {
      throw SigLIPError.onnx("推論", error)
    }
    guard let out = outputs["pooler_output"] else { throw SigLIPError.output("pooler_output が無い") }
    do {
      let info = try out.tensorTypeAndShapeInfo()
      guard info.elementType == .float, info.shape.count == 2, info.shape[0] == 1 else {
        throw SigLIPError.output("pooler_output の形 \(info.shape)")
      }
      let data = try out.tensorData()
      return Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: Float.self), count: info.shape[1].intValue))
    } catch let error as SigLIPError {
      throw error
    } catch {
      throw SigLIPError.onnx("出力の読み出し", error)
    }
  }
}

/// ONNX のファイル（protobuf の ModelProto）から出力の形を読む。初期値は長さを見て飛ばすので、mmap したファイルの大半には触れない
enum ONNXModelFile {
  /// `output` が [バッチ, 次元] の 2 階で、次元が数で決まっていればその次元
  static func outputWidth(_ file: URL, output: String) throws -> Int {
    var dims: [Int?]?
    do {
      let data = try Data(contentsOf: file, options: .alwaysMapped)
      try data.withUnsafeBytes { raw in
        var model = ProtoReader(raw)
        // ModelProto.graph → GraphProto.output
        try model.each(7) { graph in
          try graph.each(12) { info in
            if let found = try shape(of: &info, named: output) { dims = found }
          }
        }
      }
    } catch let error as ProtoReader.Malformed {
      throw SigLIPError.model(file: file.path, reason: error.reason)
    } catch let error as SigLIPError {
      throw error
    } catch {
      throw SigLIPError.model(file: file.path, reason: error.localizedDescription)
    }
    guard let dims else { throw SigLIPError.model(file: file.path, reason: "出力 \(output) が無い") }
    guard dims.count == 2, let width = dims[1], width > 0 else {
      throw SigLIPError.output("\(output) の形 [\(dims.map { $0.map(String.init) ?? "?" }.joined(separator: ", "))]")
    }
    return width
  }

  /// ValueInfoProto が `name` のものなら各次元。記号で表す次元は nil
  private static func shape(of info: inout ProtoReader, named name: String) throws -> [Int?]? {
    var found: String?
    var dims: [Int?] = []
    while let key = try info.next() {
      switch (key.field, key.wire) {
      case (1, 2): found = try info.string()
      case (2, 2):
        // TypeProto.tensor_type → TypeProto.Tensor.shape → TensorShapeProto.dim
        var type = try info.message()
        try type.each(1) { tensor in
          try tensor.each(2) { shape in
            try shape.each(1) { dim in
              var value: Int?
              while let key = try dim.next() {
                if key.field == 1, key.wire == 0 { value = Int(truncatingIfNeeded: try dim.varint()) } else { try dim.skip(key.wire) }
              }
              dims.append(value)
            }
          }
        }
      default: try info.skip(key.wire)
      }
    }
    return found == name ? dims : nil
  }
}

/// protobuf の wire format を前から読む。長さがファイルの外を指せば例外にして、途中で切れたファイルを読み込みで止める
struct ProtoReader {
  struct Malformed: Error {
    let reason: String
  }

  private let bytes: UnsafeRawBufferPointer
  private var at: Int
  private let end: Int

  init(_ bytes: UnsafeRawBufferPointer) {
    self.init(bytes, at: 0, end: bytes.count)
  }

  private init(_ bytes: UnsafeRawBufferPointer, at: Int, end: Int) {
    self.bytes = bytes
    self.at = at
    self.end = end
  }

  mutating func next() throws -> (field: UInt64, wire: UInt64)? {
    guard at < end else { return nil }
    let key = try varint()
    return (key >> 3, key & 7)
  }

  mutating func varint() throws -> UInt64 {
    var value: UInt64 = 0
    for shift in stride(from: UInt64(0), to: 64, by: 7) {
      guard at < end else { throw Malformed(reason: "\(at) バイト目で varint が途中で終わった") }
      let byte = bytes[at]
      at += 1
      value |= UInt64(byte & 0x7F) << shift
      if byte < 0x80 { return value }
    }
    throw Malformed(reason: "\(at) バイト目の varint が長すぎる")
  }

  mutating func message() throws -> ProtoReader {
    let length = try varint()
    guard length <= UInt64(end - at) else { throw Malformed(reason: "\(at) バイト目の長さ \(length) が残り \(end - at) バイトを超える") }
    let child = ProtoReader(bytes, at: at, end: at + Int(length))
    at += Int(length)
    return child
  }

  mutating func string() throws -> String {
    let child = try message()
    return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[child.at ..< child.end]), as: UTF8.self)
  }

  mutating func skip(_ wire: UInt64) throws {
    switch wire {
    case 0: _ = try varint()
    case 1: try advance(8)
    case 2: _ = try message()
    case 5: try advance(4)
    default: throw Malformed(reason: "\(at) バイト目の wire type \(wire) は読めない")
    }
  }

  /// `field` 番の子のメッセージごとに `body` を呼び、ほかの欄は飛ばす
  mutating func each(_ field: UInt64, _ body: (inout ProtoReader) throws -> Void) throws {
    while let key = try next() {
      guard key.field == field, key.wire == 2 else {
        try skip(key.wire)
        continue
      }
      var child = try message()
      try body(&child)
    }
  }

  private mutating func advance(_ count: Int) throws {
    guard count <= end - at else { throw Malformed(reason: "\(at) バイト目で \(count) バイト足りない") }
    at += count
  }
}

/// Pillow の BILINEAR と同じ縮小。CoreGraphics の `.high` や vImage の Lanczos では UI の画像の埋め込みが Python と大きくずれる
enum Resampler {
  struct Weights {
    let start: [Int]
    let count: [Int]
    let taps: Int
    let values: [Double]
  }

  static func weights(from inSize: Int, to outSize: Int) -> Weights {
    let scale = Double(inSize) / Double(outSize)
    let filterScale = max(scale, 1)
    let support = filterScale
    let taps = Int(support.rounded(.up)) * 2 + 1
    var start = [Int](repeating: 0, count: outSize)
    var count = [Int](repeating: 0, count: outSize)
    var values = [Double](repeating: 0, count: outSize * taps)
    for o in 0 ..< outSize {
      let center = (Double(o) + 0.5) * scale
      let lo = max(0, Int(center - support + 0.5))
      let hi = min(inSize, Int(center + support + 0.5))
      var total = 0.0
      for k in 0 ..< hi - lo {
        let w = max(0, 1 - abs((Double(k + lo) - center + 0.5) / filterScale))
        values[o * taps + k] = w
        total += w
      }
      if total != 0 {
        for k in 0 ..< hi - lo { values[o * taps + k] /= total }
      }
      start[o] = lo
      count[o] = hi - lo
    }
    return Weights(start: start, count: count, taps: taps, values: values)
  }

  static func bilinear(_ rgba: UnsafePointer<UInt8>, width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
    let wx = weights(from: width, to: toWidth)
    let wy = weights(from: height, to: toHeight)
    var mid = [UInt8](repeating: 0, count: height * toWidth * 3)
    mid.withUnsafeMutableBufferPointer { m in
      for y in 0 ..< height {
        let row = rgba + y * width * 4
        for x in 0 ..< toWidth {
          var acc = (0.0, 0.0, 0.0)
          for k in 0 ..< wx.count[x] {
            let w = wx.values[x * wx.taps + k]
            let p = row + (wx.start[x] + k) * 4
            acc.0 += w * Double(p[0])
            acc.1 += w * Double(p[1])
            acc.2 += w * Double(p[2])
          }
          let o = (y * toWidth + x) * 3
          m[o] = clip8(acc.0)
          m[o + 1] = clip8(acc.1)
          m[o + 2] = clip8(acc.2)
        }
      }
    }
    var out = [UInt8](repeating: 0, count: toHeight * toWidth * 3)
    mid.withUnsafeBufferPointer { m in
      out.withUnsafeMutableBufferPointer { o in
        for y in 0 ..< toHeight {
          for i in 0 ..< toWidth * 3 {
            var acc = 0.0
            for k in 0 ..< wy.count[y] {
              acc += wy.values[y * wy.taps + k] * Double(m[(wy.start[y] + k) * toWidth * 3 + i])
            }
            o[y * toWidth * 3 + i] = clip8(acc)
          }
        }
      }
    }
    return out
  }

  private static func clip8(_ v: Double) -> UInt8 {
    UInt8(min(255, max(0, (v + 0.5).rounded(.down))))
  }
}
