import Foundation

public enum TokenizerError: Error, CustomStringConvertible {
  case unreadable(String, Error)
  case malformed(String)
  case unsupported(String)

  public var description: String {
    switch self {
    case let .unreadable(path, error): "\(path) を読めない: \(error.localizedDescription)"
    case let .malformed(m): "tokenizer.json の形が違う: \(m)"
    case let .unsupported(m): "tokenizer.json の未対応の設定: \(m)"
    }
  }
}

/// Gemma の tokenizer.json が使う設定だけに対応し、ほかの設定は黙って違う id 列を作らないよう読み込みで例外にする
public struct GemmaTokenizer: Sendable {
  public let maxLength: Int
  public let padId: Int32
  private let prefix: [Int32]
  private let suffix: [Int32]
  private let scalarIds: [UInt32: Int32]
  private let byteIds: [Int32?]
  private let unkId: Int32?
  private let fuseUnk: Bool
  private let merges: [UInt64: UInt64]
  private let added: [UInt32: [AddedToken]]
  private let replace: (pattern: [UInt32], content: [UInt32])?
  private let split: [UInt32]?

  struct AddedToken: Sendable {
    let scalars: [UInt32]
    let id: Int32
  }

  public init(file: URL) throws {
    let data: Data
    do {
      data = try Data(contentsOf: file, options: .mappedIfSafe)
    } catch {
      throw TokenizerError.unreadable(file.path, error)
    }
    let parsed = try data.withUnsafeBytes { raw in
      var scanner = JSONScanner(raw.bindMemory(to: UInt8.self))
      return try Parsed(&scanner)
    }
    let config = parsed.config

    guard case let .object(padding)? = config["padding"] else { throw TokenizerError.unsupported("padding が無い（固定長の padding が要る）") }
    guard case let .object(strategy)? = padding["strategy"], case let .number(fixed)? = strategy["Fixed"], fixed > 0 else {
      throw TokenizerError.unsupported("padding.strategy は Fixed だけに対応")
    }
    guard case .string("Right")? = padding["direction"] else { throw TokenizerError.unsupported("padding.direction は Right だけに対応") }
    guard case let .number(pad)? = padding["pad_id"] else { throw TokenizerError.malformed("padding.pad_id が無い") }
    maxLength = Int(fixed)
    padId = Int32(pad)
    switch config["truncation"] {
    case .null?, nil: break
    case let .object(t)?:
      guard case .number(Double(maxLength))? = t["max_length"], case .string("Right")? = t["direction"] else {
        throw TokenizerError.unsupported("truncation は padding と同じ長さで Right のときだけ対応")
      }
    default: throw TokenizerError.malformed("truncation")
    }

    let model = parsed.model
    guard case .string("BPE")? = model.flags["type"] else { throw TokenizerError.unsupported("model.type は BPE だけに対応") }
    for key in ["dropout", "continuing_subword_prefix", "end_of_word_suffix"] {
      if let v = model.flags[key], v != .null { throw TokenizerError.unsupported("model.\(key)") }
    }
    if case .bool(true)? = model.flags["ignore_merges"] { throw TokenizerError.unsupported("model.ignore_merges") }
    guard case let .bool(byteFallback)? = model.flags["byte_fallback"], case let .bool(fuse)? = model.flags["fuse_unk"] else {
      throw TokenizerError.malformed("model.byte_fallback と model.fuse_unk が要る")
    }
    fuseUnk = fuse
    switch model.flags["unk_token"] {
    case let .string(s)?:
      guard let id = model.vocab.find(Array(s.utf8)) else { throw TokenizerError.malformed("unk_token \(s) が vocab に無い") }
      unkId = id
    case .null?, nil: unkId = nil
    default: throw TokenizerError.malformed("model.unk_token")
    }
    byteIds = (0 ..< 256).map { b in
      byteFallback ? model.vocab.find(Array(String(format: "<0x%02X>", b).utf8)) : nil
    }
    guard unkId != nil || byteIds.allSatisfy({ $0 != nil }) else {
      throw TokenizerError.unsupported("unk_token が無く、byte fallback もすべてのバイトを表せない")
    }
    scalarIds = model.vocab.singleScalars
    merges = try model.resolveMerges()

    var byFirst: [UInt32: [AddedToken]] = [:]
    guard case let .array(tokens)? = config["added_tokens"] else { throw TokenizerError.malformed("added_tokens") }
    for token in tokens {
      guard case let .object(t) = token, case let .string(content)? = t["content"], case let .number(id)? = t["id"] else {
        throw TokenizerError.malformed("added_tokens の要素")
      }
      for flag in ["single_word", "lstrip", "rstrip", "normalized"] {
        if case .bool(true)? = t[flag] { throw TokenizerError.unsupported("added_tokens の \(flag)（\(content)）") }
      }
      let scalars = content.unicodeScalars.map(\.value)
      guard let first = scalars.first else { throw TokenizerError.malformed("空の added token") }
      byFirst[first, default: []].append(AddedToken(scalars: scalars, id: Int32(id)))
    }
    added = byFirst.mapValues { $0.sorted { $0.scalars.count > $1.scalars.count } }

    switch config["normalizer"] {
    case .null?, nil: replace = nil
    case let .object(n)?:
      guard case .string("Replace")? = n["type"], case let .object(p)? = n["pattern"], case let .string(pattern)? = p["String"],
            case let .string(content)? = n["content"], !pattern.isEmpty
      else { throw TokenizerError.unsupported("normalizer は String の Replace だけに対応") }
      replace = (pattern.unicodeScalars.map(\.value), content.unicodeScalars.map(\.value))
    default: throw TokenizerError.malformed("normalizer")
    }

    switch config["pre_tokenizer"] {
    case .null?, nil: split = nil
    case let .object(p)?:
      guard case .string("Split")? = p["type"], case let .object(pat)? = p["pattern"], case let .string(pattern)? = pat["String"],
            case .string("MergedWithPrevious")? = p["behavior"], case .bool(false)? = p["invert"], !pattern.isEmpty
      else { throw TokenizerError.unsupported("pre_tokenizer は String の Split（MergedWithPrevious）だけに対応") }
      split = pattern.unicodeScalars.map(\.value)
    default: throw TokenizerError.malformed("pre_tokenizer")
    }

    switch config["post_processor"] {
    case .null?, nil:
      prefix = []
      suffix = []
    case let .object(p)?:
      guard case .string("TemplateProcessing")? = p["type"], case let .array(single)? = p["single"], case let .object(specials)? = p["special_tokens"] else {
        throw TokenizerError.unsupported("post_processor は TemplateProcessing だけに対応")
      }
      var before: [Int32] = []
      var after: [Int32] = []
      var seenSequence = false
      for item in single {
        guard case let .object(entry) = item else { throw TokenizerError.malformed("post_processor.single") }
        if case let .object(seq)? = entry["Sequence"] {
          guard case .string("A")? = seq["id"], !seenSequence else { throw TokenizerError.unsupported("post_processor.single の Sequence") }
          seenSequence = true
        } else if case let .object(special)? = entry["SpecialToken"], case let .string(name)? = special["id"] {
          guard case let .object(def)? = specials[name], case let .array(ids)? = def["ids"] else {
            throw TokenizerError.malformed("post_processor.special_tokens に \(name) が無い")
          }
          let values = try ids.map { v -> Int32 in
            guard case let .number(n) = v else { throw TokenizerError.malformed("post_processor.special_tokens.\(name).ids") }
            return Int32(n)
          }
          if seenSequence { after += values } else { before += values }
        } else {
          throw TokenizerError.malformed("post_processor.single の要素")
        }
      }
      guard seenSequence else { throw TokenizerError.malformed("post_processor.single に Sequence が無い") }
      prefix = before
      suffix = after
    default: throw TokenizerError.malformed("post_processor")
    }
    guard maxLength > prefix.count + suffix.count else { throw TokenizerError.malformed("padding の長さが特殊トークンより短い") }
  }

  public func encode(_ text: String) -> [Int32] {
    var ids: [Int32] = []
    let scalars = text.unicodeScalars.map(\.value)
    var start = 0
    var i = 0
    while i < scalars.count {
      if let token = added[scalars[i]]?.first(where: { matches($0.scalars, scalars, at: i) }) {
        if start < i { model(scalars[start ..< i], into: &ids) }
        ids.append(token.id)
        i += token.scalars.count
        start = i
      } else {
        i += 1
      }
    }
    if start < scalars.count { model(scalars[start...], into: &ids) }
    let body = maxLength - prefix.count - suffix.count
    if ids.count > body { ids.removeLast(ids.count - body) }
    var out = prefix + ids + suffix
    out.append(contentsOf: repeatElement(padId, count: maxLength - out.count))
    return out
  }

  private func matches(_ pattern: [UInt32], _ text: [UInt32], at i: Int) -> Bool {
    guard i + pattern.count <= text.count else { return false }
    for k in 0 ..< pattern.count where text[i + k] != pattern[k] { return false }
    return true
  }

  private func model(_ piece: ArraySlice<UInt32>, into ids: inout [Int32]) {
    var normalized: [UInt32] = []
    normalized.reserveCapacity(piece.count)
    if let replace {
      var i = piece.startIndex
      while i < piece.endIndex {
        if piece[i] == replace.pattern[0], i + replace.pattern.count <= piece.endIndex, piece[i ..< i + replace.pattern.count].elementsEqual(replace.pattern) {
          normalized += replace.content
          i += replace.pattern.count
        } else {
          normalized.append(piece[i])
          i += 1
        }
      }
    } else {
      normalized += piece
    }
    guard let split else { return bpe(normalized[...], into: &ids) }
    var start = 0
    var i = 0
    while i < normalized.count {
      if normalized[i] == split[0], i + split.count <= normalized.count, normalized[i ..< i + split.count].elementsEqual(split) {
        i += split.count
        bpe(normalized[start ..< i], into: &ids)
        start = i
      } else {
        i += 1
      }
    }
    if start < normalized.count { bpe(normalized[start...], into: &ids) }
  }

  private struct Symbol {
    var id: Int32
    var prev: Int
    var next: Int
    var alive = true
  }

  /// 古い候補の扱いまで tokenizers と同じにしないと id 列がずれるので、`BPE::merge_word` と `Word::merge_all` の手順をそのままなぞる
  private func bpe(_ word: ArraySlice<UInt32>, into ids: inout [Int32]) {
    guard !word.isEmpty else { return }
    var symbols: [Symbol] = []
    symbols.reserveCapacity(word.count)
    func add(_ id: Int32) {
      if !symbols.isEmpty { symbols[symbols.count - 1].next = symbols.count }
      symbols.append(Symbol(id: id, prev: symbols.count - 1, next: -1))
    }
    var pendingUnk = false
    for scalar in word {
      if let id = scalarIds[scalar] {
        if pendingUnk, let unkId { add(unkId); pendingUnk = false }
        add(id)
        continue
      }
      let utf8 = Array(String(UnicodeScalar(scalar)!).utf8)
      let bytes = utf8.map { byteIds[Int($0)] }
      if !bytes.isEmpty, bytes.allSatisfy({ $0 != nil }) {
        for b in bytes { add(b!) }
        continue
      }
      guard let unkId else { preconditionFailure("init で unk か全バイトの byte fallback を必須にしている") }
      if pendingUnk, !fuseUnk { add(unkId) }
      pendingUnk = true
    }
    if pendingUnk, let unkId { add(unkId) }

    var heap = MergeHeap()
    for i in 0 ..< symbols.count - 1 {
      if let m = merges[Self.key(symbols[i].id, symbols[i + 1].id)] { heap.push(Merge(m, pos: i)) }
    }
    while let top = heap.pop() {
      let pos = top.pos
      guard symbols[pos].alive, symbols[pos].next != -1 else { continue }
      let nextPos = symbols[pos].next
      let right = symbols[nextPos]
      guard let m = merges[Self.key(symbols[pos].id, right.id)], Int32(truncatingIfNeeded: m) == top.newId else { continue }
      symbols[pos].id = top.newId
      symbols[pos].next = right.next
      symbols[nextPos].alive = false
      if right.next >= 0 { symbols[right.next].prev = pos }
      let current = symbols[pos]
      if current.prev >= 0, let m = merges[Self.key(symbols[current.prev].id, current.id)] {
        heap.push(Merge(m, pos: current.prev))
      }
      if current.next >= 0, let m = merges[Self.key(current.id, symbols[current.next].id)] {
        heap.push(Merge(m, pos: pos))
      }
    }
    for s in symbols where s.alive { ids.append(s.id) }
  }

  static func key(_ a: Int32, _ b: Int32) -> UInt64 {
    UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b))
  }
}

private struct Merge {
  let rank: UInt32
  let pos: Int
  let newId: Int32

  init(_ packed: UInt64, pos: Int) {
    rank = UInt32(truncatingIfNeeded: packed >> 32)
    newId = Int32(truncatingIfNeeded: packed)
    self.pos = pos
  }

  func before(_ other: Merge) -> Bool {
    rank != other.rank ? rank < other.rank : pos < other.pos
  }
}

private struct MergeHeap {
  private var items: [Merge] = []

  mutating func push(_ m: Merge) {
    items.append(m)
    var i = items.count - 1
    while i > 0 {
      let parent = (i - 1) / 2
      guard items[i].before(items[parent]) else { break }
      items.swapAt(i, parent)
      i = parent
    }
  }

  mutating func pop() -> Merge? {
    guard let top = items.first else { return nil }
    let last = items.removeLast()
    guard !items.isEmpty else { return top }
    items[0] = last
    var i = 0
    while true {
      let l = 2 * i + 1
      let r = l + 1
      var best = i
      if l < items.count, items[l].before(items[best]) { best = l }
      if r < items.count, items[r].before(items[best]) { best = r }
      guard best != i else { return top }
      items.swapAt(i, best)
      i = best
    }
  }
}

/// tokenizer.json を読んだ値
indirect enum TokenizerJSON: Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([TokenizerJSON])
  case object([String: TokenizerJSON])
}

/// vocab の文字列はバイト列のまま扱う。Swift の String は正準等価な文字列を同一視するため、別のトークンが衝突する
struct ByteVocab {
  var pool: [UInt8] = []
  var starts: [Int32] = []
  var lengths: [Int32] = []
  var ids: [Int32] = []
  private var slots: [Int32] = []
  private var mask = 0

  mutating func append(start: Int, id: Int32) {
    starts.append(Int32(start))
    lengths.append(Int32(pool.count - start))
    ids.append(id)
  }

  mutating func buildIndex() throws {
    var capacity = 1
    while capacity < ids.count * 2 { capacity <<= 1 }
    mask = capacity - 1
    slots = Array(repeating: -1, count: capacity)
    try pool.withUnsafeBufferPointer { p in
      for e in 0 ..< ids.count {
        let key = UnsafeBufferPointer(rebasing: p[Int(starts[e]) ..< Int(starts[e] + lengths[e])])
        var slot = Self.hash(key) & mask
        while slots[slot] >= 0 {
          if Self.equal(p, slots[slot], starts, lengths, key) { throw TokenizerError.malformed("vocab の重複") }
          slot = (slot + 1) & mask
        }
        slots[slot] = Int32(e)
      }
    }
  }

  func find(_ key: [UInt8]) -> Int32? {
    key.withUnsafeBufferPointer { k in pool.withUnsafeBufferPointer { p in find(k, pool: p) } }
  }

  func find(_ key: UnsafeBufferPointer<UInt8>, pool p: UnsafeBufferPointer<UInt8>) -> Int32? {
    var slot = Self.hash(key) & mask
    while slots[slot] >= 0 {
      if Self.equal(p, slots[slot], starts, lengths, key) { return ids[Int(slots[slot])] }
      slot = (slot + 1) & mask
    }
    return nil
  }

  var singleScalars: [UInt32: Int32] {
    var out: [UInt32: Int32] = [:]
    for e in 0 ..< ids.count {
      let s = Int(starts[e])
      let n = Int(lengths[e])
      let lead = pool[s]
      let expected = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
      guard n == expected else { continue }
      var v = UInt32(n == 1 ? lead : n == 2 ? lead & 0x1F : n == 3 ? lead & 0x0F : lead & 0x07)
      for k in 1 ..< n { v = v << 6 | UInt32(pool[s + k] & 0x3F) }
      out[v] = ids[e]
    }
    return out
  }

  private static func equal(_ p: UnsafeBufferPointer<UInt8>, _ entry: Int32, _ starts: [Int32], _ lengths: [Int32], _ key: UnsafeBufferPointer<UInt8>) -> Bool {
    let n = Int(lengths[Int(entry)])
    guard n == key.count else { return false }
    let s = Int(starts[Int(entry)])
    return n == 0 || memcmp(p.baseAddress! + s, key.baseAddress!, n) == 0
  }

  private static func hash(_ key: UnsafeBufferPointer<UInt8>) -> Int {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for b in key { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
    return Int(truncatingIfNeeded: h ^ (h >> 29))
  }
}

struct BPEModel {
  var flags: [String: TokenizerJSON] = [:]
  var vocab = ByteVocab()
  /// 左右を続けて置き、結合後の文字列を複製せずに引く
  var mergePool: [UInt8] = []
  var mergeStarts: [Int32] = []
  var mergeLeft: [Int32] = []
  var mergeRight: [Int32] = []

  func resolveMerges() throws -> [UInt64: UInt64] {
    var out: [UInt64: UInt64] = [:]
    out.reserveCapacity(mergeStarts.count)
    try mergePool.withUnsafeBufferPointer { m in
      try vocab.pool.withUnsafeBufferPointer { p in
        for r in 0 ..< mergeStarts.count {
          let s = Int(mergeStarts[r])
          let l = Int(mergeLeft[r])
          let n = l + Int(mergeRight[r])
          guard let a = vocab.find(UnsafeBufferPointer(rebasing: m[s ..< s + l]), pool: p),
                let b = vocab.find(UnsafeBufferPointer(rebasing: m[s + l ..< s + n]), pool: p),
                let c = vocab.find(UnsafeBufferPointer(rebasing: m[s ..< s + n]), pool: p)
          else {
            throw TokenizerError.malformed("merges の \(r) 番目のトークンが vocab に無い")
          }
          out[GemmaTokenizer.key(a, b)] = UInt64(r) << 32 | UInt64(UInt32(bitPattern: c))
        }
      }
    }
    return out
  }
}

struct Parsed {
  var config: [String: TokenizerJSON] = [:]
  var model = BPEModel()

  init(_ s: inout JSONScanner) throws {
    var sawModel = false
    try s.expect(UInt8(ascii: "{"))
    var first = true
    while try s.more(UInt8(ascii: "}"), &first) {
      let key = try s.key()
      if key == "model" {
        try parseModel(&s)
        sawModel = true
      } else {
        config[key] = try s.value()
      }
    }
    guard sawModel else { throw TokenizerError.malformed("model が無い") }
    try model.vocab.buildIndex()
  }

  private mutating func parseModel(_ s: inout JSONScanner) throws {
    try s.expect(UInt8(ascii: "{"))
    var first = true
    while try s.more(UInt8(ascii: "}"), &first) {
      let key = try s.key()
      switch key {
      case "vocab":
        try s.expect(UInt8(ascii: "{"))
        var f = true
        while try s.more(UInt8(ascii: "}"), &f) {
          let start = model.vocab.pool.count
          try s.string(into: &model.vocab.pool)
          try s.expect(UInt8(ascii: ":"))
          let id = try s.integer()
          model.vocab.append(start: start, id: Int32(id))
        }
      case "merges":
        try s.expect(UInt8(ascii: "["))
        var f = true
        while try s.more(UInt8(ascii: "]"), &f) {
          guard s.peek() == UInt8(ascii: "[") else { throw TokenizerError.unsupported("merges は [左, 右] の配列の形だけに対応") }
          try s.expect(UInt8(ascii: "["))
          let start = model.mergePool.count
          try s.string(into: &model.mergePool)
          let mid = model.mergePool.count
          try s.expect(UInt8(ascii: ","))
          try s.string(into: &model.mergePool)
          try s.expect(UInt8(ascii: "]"))
          model.mergeStarts.append(Int32(start))
          model.mergeLeft.append(Int32(mid - start))
          model.mergeRight.append(Int32(model.mergePool.count - mid))
        }
      default:
        model.flags[key] = try s.value()
      }
    }
  }
}

struct JSONScanner {
  private let b: UnsafeBufferPointer<UInt8>
  private var i = 0

  init(_ bytes: UnsafeBufferPointer<UInt8>) {
    b = bytes
  }

  func peek() -> UInt8? {
    var j = i
    while j < b.count, Self.isSpace(b[j]) { j += 1 }
    return j < b.count ? b[j] : nil
  }

  private static func isSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
  }

  private mutating func skipSpace() {
    while i < b.count, Self.isSpace(b[i]) { i += 1 }
  }

  private func fail(_ what: String) -> TokenizerError {
    .malformed("\(i) バイト目: \(what)")
  }

  mutating func expect(_ c: UInt8) throws {
    skipSpace()
    guard i < b.count, b[i] == c else { throw fail("\(Character(UnicodeScalar(c))) が要る") }
    i += 1
  }

  mutating func more(_ close: UInt8, _ first: inout Bool) throws -> Bool {
    skipSpace()
    guard i < b.count else { throw fail("途中で終わった") }
    if b[i] == close {
      i += 1
      return false
    }
    if !first { try expect(UInt8(ascii: ",")) }
    first = false
    return true
  }

  mutating func key() throws -> String {
    var buf: [UInt8] = []
    try string(into: &buf)
    try expect(UInt8(ascii: ":"))
    return String(decoding: buf, as: UTF8.self)
  }

  mutating func string(into out: inout [UInt8]) throws {
    try expect(UInt8(ascii: "\""))
    while true {
      guard i < b.count else { throw fail("文字列が閉じていない") }
      let c = b[i]
      i += 1
      if c == UInt8(ascii: "\"") { return }
      guard c == UInt8(ascii: "\\") else {
        out.append(c)
        continue
      }
      guard i < b.count else { throw fail("エスケープが途中で終わった") }
      let e = b[i]
      i += 1
      switch e {
      case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
      case UInt8(ascii: "b"): out.append(0x08)
      case UInt8(ascii: "f"): out.append(0x0C)
      case UInt8(ascii: "n"): out.append(0x0A)
      case UInt8(ascii: "r"): out.append(0x0D)
      case UInt8(ascii: "t"): out.append(0x09)
      case UInt8(ascii: "u"):
        var v = try hex4()
        if (0xD800 ..< 0xDC00).contains(v) {
          guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else { throw fail("サロゲートの片割れ") }
          i += 2
          let low = try hex4()
          guard (0xDC00 ..< 0xE000).contains(low) else { throw fail("サロゲートの片割れ") }
          v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
        } else if (0xDC00 ..< 0xE000).contains(v) {
          throw fail("サロゲートの片割れ")
        }
        out.append(contentsOf: String(UnicodeScalar(v)!).utf8)
      default: throw fail("未知のエスケープ")
      }
    }
  }

  private mutating func hex4() throws -> UInt32 {
    guard i + 4 <= b.count else { throw fail("\\u が途中で終わった") }
    var v: UInt32 = 0
    for _ in 0 ..< 4 {
      let c = b[i]
      i += 1
      let d: UInt8
      switch c {
      case UInt8(ascii: "0") ... UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
      case UInt8(ascii: "a") ... UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A") ... UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
      default: throw fail("\\u の 16 進数")
      }
      v = v << 4 | UInt32(d)
    }
    return v
  }

  mutating func integer() throws -> Int {
    skipSpace()
    var negative = false
    if i < b.count, b[i] == UInt8(ascii: "-") {
      negative = true
      i += 1
    }
    let start = i
    var v = 0
    while i < b.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(b[i]) {
      v = v * 10 + Int(b[i] - UInt8(ascii: "0"))
      i += 1
    }
    guard i > start else { throw fail("整数が要る") }
    return negative ? -v : v
  }

  mutating func value() throws -> TokenizerJSON {
    skipSpace()
    guard i < b.count else { throw fail("値が要る") }
    switch b[i] {
    case UInt8(ascii: "{"):
      i += 1
      var out: [String: TokenizerJSON] = [:]
      var first = true
      while try more(UInt8(ascii: "}"), &first) {
        let k = try key()
        out[k] = try value()
      }
      return .object(out)
    case UInt8(ascii: "["):
      i += 1
      var out: [TokenizerJSON] = []
      var first = true
      while try more(UInt8(ascii: "]"), &first) { out.append(try value()) }
      return .array(out)
    case UInt8(ascii: "\""):
      var buf: [UInt8] = []
      try string(into: &buf)
      return .string(String(decoding: buf, as: UTF8.self))
    case UInt8(ascii: "t"): try literal("true"); return .bool(true)
    case UInt8(ascii: "f"): try literal("false"); return .bool(false)
    case UInt8(ascii: "n"): try literal("null"); return .null
    default:
      let start = i
      while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
      guard let v = Double(String(decoding: UnsafeBufferPointer(rebasing: b[start ..< i]), as: UTF8.self)) else { throw fail("数値") }
      return .number(v)
    }
  }

  private mutating func literal(_ word: String) throws {
    for c in word.utf8 {
      guard i < b.count, b[i] == c else { throw fail(word) }
      i += 1
    }
  }
}
