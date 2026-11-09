import Accelerate
import Foundation

/// 全件の埋め込みを 1 本の行列（行優先、1 行 1 件）に載せ、内積で近いものを引く。
public final class VectorIndex: @unchecked Sendable {
  public let dimension: Int
  private var matrix: [Float] = []
  private var ids: [String] = []
  private var kinds: [ShotKind] = []
  private var rows: [String: Int] = [:]
  private let lock = NSLock()

  public init(dimension: Int) {
    self.dimension = dimension
  }

  public var count: Int {
    lock.withLock { ids.count }
  }

  public func set(_ id: String, kind: ShotKind, _ vector: [Float]) {
    precondition(vector.count == dimension, "埋め込みの次元が \(vector.count)（期待は \(dimension)）")
    lock.withLock {
      if let row = rows[id] {
        matrix.replaceSubrange(row * dimension ..< (row + 1) * dimension, with: vector)
        kinds[row] = kind
      } else {
        rows[id] = ids.count
        ids.append(id)
        kinds.append(kind)
        matrix.append(contentsOf: vector)
      }
    }
  }

  public func vector(_ id: String) -> [Float]? {
    lock.withLock {
      guard let row = rows[id] else { return nil }
      return Array(matrix[row * dimension ..< (row + 1) * dimension])
    }
  }

  public func entry(_ id: String) -> (kind: ShotKind, vector: [Float])? {
    lock.withLock {
      guard let row = rows[id] else { return nil }
      return (kinds[row], Array(matrix[row * dimension ..< (row + 1) * dimension]))
    }
  }

  /// `query` との内積の大きい順。`include` が偽を返すものは除く。
  public func nearest(_ query: [Float], limit: Int, include: (_ id: String, _ kind: ShotKind) -> Bool = { _, _ in true }) -> [(id: String, score: Float)] {
    precondition(query.count == dimension, "検索の埋め込みの次元が \(query.count)（期待は \(dimension)）")
    let (scores, names, types) = lock.withLock { () -> ([Float], [String], [ShotKind]) in
      let n = ids.count
      guard n > 0 else { return ([], [], []) }
      var out = [Float](repeating: 0, count: n)
      cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(dimension), 1, matrix, Int32(dimension), query, 1, 0, &out, 1)
      return (out, ids, kinds)
    }
    let order = scores.indices.filter { include(names[$0], types[$0]) }.sorted { scores[$0] > scores[$1] }
    return order.prefix(limit).map { (names[$0], scores[$0]) }
  }
}
