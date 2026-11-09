import Accelerate
import Foundation

/// 検索結果の並べ替え。どれも入力だけで結果が決まる。
public enum Ranking {
  /// Reciprocal Rank Fusion。順位は 1 から数え、各リストでの 1 / (k + 順位) を足す。同点は先に現れた順。
  public static func fuse(_ lists: [[String]], k: Double = 60) -> [String] {
    fuse(weighted: lists.map { (ids: $0, weight: 1) }, k: k)
  }

  /// 重み付きの RRF。各リストでの weight / (k + 順位) を足す。
  public static func fuse(weighted lists: [(ids: [String], weight: Double)], k: Double = 60) -> [String] {
    var score: [String: Double] = [:]
    var first: [String: Int] = [:]
    var seen = 0
    for list in lists {
      for (index, id) in list.ids.enumerated() {
        score[id, default: 0] += list.weight / (k + Double(index + 1))
        if first[id] == nil {
          first[id] = seen
          seen += 1
        }
      }
    }
    return score.keys.sorted { a, b in
      score[a]! != score[b]! ? score[a]! > score[b]! : first[a]! < first[b]!
    }
  }

  public struct Modality: Equatable, Sendable {
    public var kinds: Set<ShotKind>
    public var weight: Double
  }

  /// 埋め込みを比べる種類の組。静止画と動画はサムネイルの画像から、文章は文章から埋め込むので、検索語との内積の水準が組ごとに大きく違う
  /// （SigLIP 2 では、検索語と画像は 0.2 以下、検索語と文章は 0.7 以上）。近い順は組ごとに作り、順位を RRF でまとめる。
  /// 文章の組の重みを半分にして、文章は全文検索でも当たったときだけメディアと並ぶようにする。
  public static let modalities: [Modality] = [Modality(kinds: [.image, .video], weight: 1), Modality(kinds: [.text], weight: 0.5)]

  /// `kinds`（nil なら全種類）を組に分ける。空の組は除く。
  public static func modalities(of kinds: Set<ShotKind>?) -> [Modality] {
    modalities.map { Modality(kinds: $0.kinds.intersection(kinds ?? Set(ShotKind.allCases)), weight: $0.weight) }.filter { !$0.kinds.isEmpty }
  }

  /// 組ごとに内積の大きい順に並べ、順位を重み付きの RRF でまとめる。
  public static func acrossModalities(_ scored: [(id: String, kind: ShotKind, score: Float)]) -> [String] {
    fuse(weighted: modalities.map { group in
      (ids: scored.filter { group.kinds.contains($0.kind) }.sorted { $0.score > $1.score }.map(\.id), weight: group.weight)
    })
  }

  public struct Candidate: Sendable {
    public var id: String
    public var source: String
    /// 画像として埋め込みを比べてよいもの（image と video）
    public var visual: Bool
    /// メディアの画素数。分からなければ 0
    public var area: Double
    public var fromList: Bool
    /// 利用者が選んだもの
    public var selected: Bool
    public var vector: [Float]?

    public init(id: String, source: String, visual: Bool, area: Double, fromList: Bool, selected: Bool, vector: [Float]?) {
      self.id = id
      self.source = source
      self.visual = visual
      self.area = area
      self.fromList = fromList
      self.selected = selected
      self.vector = vector
    }
  }

  /// 埋め込みの内積が `threshold` 以上の画像どうしを 1 件にまとめる。
  /// 位置は群の中で最も上位のものの位置。代表は利用者が選んだもの、次にメディアが大きいもの、次に `list` で取ったもの。戻り値は (代表, 件数)。
  public static func collapse(_ items: [Candidate], threshold: Float = 0.96) -> [(Candidate, Int)] {
    var groups: [[Int]] = []
    for (i, item) in items.enumerated() {
      guard item.visual, let v = item.vector else {
        groups.append([i])
        continue
      }
      let match = groups.firstIndex { group in
        group.contains { j in
          guard items[j].visual, let w = items[j].vector, w.count == v.count else { return false }
          return dot(v, w) >= threshold
        }
      }
      if let match { groups[match].append(i) } else { groups.append([i]) }
    }
    return groups.map { group in
      let best = group.max { a, b in
        let x = items[a], y = items[b]
        if x.selected != y.selected { return !x.selected }
        if x.area != y.area { return x.area < y.area }
        if x.fromList != y.fromList { return !x.fromList }
        return a > b
      }!
      return (items[best], group.count)
    }
  }

  /// `window` 件ごとの窓の中で、同じサイトが続かないように並べ替える。窓をまたいだ順位は動かさない。
  public static func interleave<T>(_ items: [T], window: Int = 12, source: (T) -> String) -> [T] {
    var out: [T] = []
    out.reserveCapacity(items.count)
    var start = 0
    while start < items.count {
      var pool = Array(items[start ..< min(start + window, items.count)])
      while !pool.isEmpty {
        let previous = out.last.map(source)
        let next = pool.firstIndex { source($0) != previous } ?? 0
        out.append(pool.remove(at: next))
      }
      start += window
    }
    return out
  }

  public static func dot(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "次元の違うベクトルの内積")
    var result: Float = 0
    vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
    return result
  }

  public static func normalized(_ v: [Float]) -> [Float] {
    var norm: Float = 0
    vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
    norm = norm.squareRoot()
    guard norm > 0 else { return v }
    var scale = 1 / norm
    var out = [Float](repeating: 0, count: v.count)
    vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
    return out
  }
}
