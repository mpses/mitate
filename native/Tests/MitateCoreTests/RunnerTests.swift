import Foundation
import Testing
@testable import MitateCore

/// サイトの列と live 検索の上限。上限は、列で順番が来て問い合わせを始める時刻で判定する。
@MainActor
struct RunnerTests {
  final class Clock: @unchecked Sendable {
    var events: [(String, Date)] = []
    let lock = NSLock()
    func mark(_ name: String) { lock.withLock { events.append((name, Date())) } }
    func time(_ name: String) -> Date? { lock.withLock { events.first { $0.0 == name }?.1 } }
    var names: [String] { lock.withLock { events.map(\.0) } }
  }

  @Test func callsRunInOrderAndKeepThePace() async throws {
    let lanes = SiteLanes()
    let clock = Clock()
    let tasks = (0 ..< 3).map { i in
      Task { @MainActor in
        try await lanes.run("s", pace: 0.2, label: "list", admit: nil) {
          clock.mark("start\(i)")
          try await Task.sleep(nanoseconds: 100_000_000)
          clock.mark("end\(i)")
        }
      }
    }
    for task in tasks { try await task.value }
    #expect(clock.names == ["start0", "end0", "start1", "end1", "start2", "end2"])
    for i in 1 ..< 3 {
      let gap = try #require(clock.time("start\(i)")).timeIntervalSince(try #require(clock.time("end\(i - 1)")))
      #expect(gap >= 0.2, "前の終わりから \(gap) 秒で始まった")
    }
  }

  @Test func liveLimitIsJudgedWhenTheCallStarts() async throws {
    let lanes = SiteLanes()
    let limiter = LiveLimiter(spacing: 0.5, window: 60, perWindow: 6)
    let clock = Clock()
    // 同期が 1 秒のあいだ列を塞ぐ。
    let list = Task { @MainActor in
      try await lanes.run("s", pace: 0.05, label: "list", admit: nil) {
        clock.mark("list")
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    let first = Task { @MainActor in
      try await lanes.run("s", pace: 0.05, label: "search", admit: { try limiter.admit("s") }) { clock.mark("a") }
    }
    // 受け付けた時刻どうしは 0.5 秒より離れているが、列が空いたあとに立て続けに始まるので 2 件目は断る。
    try await Task.sleep(nanoseconds: 550_000_000)
    let second = Task { @MainActor in
      try await lanes.run("s", pace: 0.05, label: "search", admit: { try limiter.admit("s") }) { clock.mark("b") }
    }
    try await list.value
    try await first.value
    await #expect(throws: LiveError.self) { try await second.value }
    #expect(clock.names == ["list", "a"])
    // 断った呼び出しのあとも列は進む。
    try await Task.sleep(nanoseconds: 600_000_000)
    try await lanes.run("s", pace: 0.05, label: "search", admit: { try limiter.admit("s") }) { clock.mark("c") }
    #expect(clock.names == ["list", "a", "c"])
  }

  @Test func limiterCountsPerSiteAndPerMinute() throws {
    let limiter = LiveLimiter()
    let t0 = Date()
    for i in 0 ..< 6 { try limiter.admit("p", now: t0.addingTimeInterval(Double(i) * 5)) }
    #expect(throws: LiveError.self) { try limiter.admit("p", now: t0.addingTimeInterval(30)) }
    #expect(throws: LiveError.self) { try limiter.admit("p", now: t0.addingTimeInterval(27)) }
    try limiter.admit("x", now: t0.addingTimeInterval(27))
    try limiter.admit("p", now: t0.addingTimeInterval(61))
  }
}
