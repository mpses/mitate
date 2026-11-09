import Testing
@testable import MitateCore

struct RankingTests {
  @Test func fuseAddsReciprocalRanks() {
    // b は両方の 2 位以内、a は片方の 1 位だけ。
    let fused = Ranking.fuse([["a", "b", "c"], ["b", "d"]])
    #expect(fused.first == "b")
    #expect(Set(fused) == ["a", "b", "c", "d"])
    #expect(fused.firstIndex(of: "a")! < fused.firstIndex(of: "d")!)
  }

  @Test func fuseBreaksTiesByFirstAppearance() {
    #expect(Ranking.fuse([["x", "y"], ["y", "x"]]) == ["x", "y"])
    #expect(Ranking.fuse([]) == [])
  }

  private func candidate(_ id: String, source: String = "s", visual: Bool = true, area: Double = 0, fromList: Bool = true, selected: Bool = false, vector: [Float]?) -> Ranking.Candidate {
    Ranking.Candidate(id: id, source: source, visual: visual, area: area, fromList: fromList, selected: selected, vector: vector)
  }

  @Test func collapseGroupsNearDuplicateImages() {
    let a: [Float] = [1, 0, 0]
    let near = Ranking.normalized([1, 0.2, 0])
    let far: [Float] = [0, 1, 0]
    let result = Ranking.collapse([candidate("a", vector: a), candidate("b", vector: far), candidate("c", vector: near)])
    #expect(result.map(\.0.id) == ["a", "b"])
    #expect(result.map(\.1) == [2, 1])
  }

  @Test func collapseKeepsTextAndUnembeddedApart() {
    let v: [Float] = [1, 0]
    let result = Ranking.collapse([candidate("t1", visual: false, vector: v), candidate("t2", visual: false, vector: v), candidate("n", vector: nil)])
    #expect(result.map(\.1) == [1, 1, 1])
  }

  @Test func collapsePrefersSelectedThenLargerThenListed() {
    let v: [Float] = [0, 1]
    let big = candidate("big", area: 4_000_000, fromList: false, vector: v)
    let picked = candidate("picked", area: 100, selected: true, vector: v)
    #expect(Ranking.collapse([big, picked]).first?.0.id == "picked")
    let listed = candidate("listed", area: 4_000_000, fromList: true, vector: v)
    #expect(Ranking.collapse([big, listed]).first?.0.id == "listed")
    let small = candidate("small", area: 10, fromList: true, vector: v)
    #expect(Ranking.collapse([small, big]).first?.0.id == "big")
  }

  @Test func interleaveAvoidsRepeatsWithinWindow() {
    let items = ["a1", "a2", "a3", "b1", "b2", "c1"]
    let out = Ranking.interleave(items, window: 12) { String($0.prefix(1)) }
    #expect(Set(out) == Set(items))
    for (x, y) in zip(out, out.dropFirst()) where x.prefix(1) == y.prefix(1) {
      // 残りが同じサイトだけになったときに限り続いてよい。
      let rest = out[out.firstIndex(of: y)!...]
      #expect(rest.allSatisfy { $0.prefix(1) == y.prefix(1) })
    }
    #expect(out.first == "a1")
  }

  @Test func interleaveDoesNotMoveAcrossWindows() {
    let items = ["a1", "a2", "b1", "b2"]
    let out = Ranking.interleave(items, window: 2) { String($0.prefix(1)) }
    #expect(Array(out.prefix(2)).sorted() == ["a1", "a2"])
    #expect(Array(out.suffix(2)).sorted() == ["b1", "b2"])
  }

  /// 文章どうしの内積は画像との内積よりずっと高いので、そのまま混ぜると文章が画像をすべて押しのける。文章の組は重みも低い。
  @Test func modalitiesAreRankedSeparately() {
    let out = Ranking.acrossModalities([
      (id: "t:1", kind: .text, score: 0.79),
      (id: "t:2", kind: .text, score: 0.78),
      (id: "t:3", kind: .text, score: 0.77),
      (id: "i:1", kind: .image, score: 0.19),
      (id: "v:1", kind: .video, score: 0.15),
    ])
    #expect(out == ["i:1", "v:1", "t:1", "t:2", "t:3"])
    #expect(Ranking.modalities(of: nil).map(\.kinds) == [[.image, .video], [.text]])
    #expect(Ranking.modalities(of: [.video]).map(\.kinds) == [[.video]])
    #expect(Ranking.modalities(of: [.text, .image]).map(\.kinds) == [[.image], [.text]])
  }

  /// 文章は全文検索でも当たれば、埋め込みだけで当たった画像より上に来る。
  @Test func textNeedsFullTextToOutrankMedia() {
    let fts = ["t:hit"]
    let media = ["i:1", "i:2", "i:3"]
    let text = ["t:near", "t:hit"]
    let out = Ranking.fuse(weighted: [(ids: fts, weight: 1), (ids: media, weight: 1), (ids: text, weight: 0.5)])
    #expect(out.first == "t:hit")
    #expect(out.firstIndex(of: "t:near")! > out.firstIndex(of: "i:3")!)
  }
}
