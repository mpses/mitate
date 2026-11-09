import Foundation
import Testing
@testable import MitateCore

/// 呼び出しが途切れたあとの片付け（隠しタブを閉じる）。片付けはサイトの列の中で走り、呼び出しと重ならない。
@MainActor
struct SiteLanesIdleTests {
  final class Clock: @unchecked Sendable {
    var events: [(String, Date)] = []
    let lock = NSLock()
    func mark(_ name: String) { lock.withLock { events.append((name, Date())) } }
    func time(_ name: String) -> Date? { lock.withLock { events.first { $0.0 == name }?.1 } }
    var names: [String] { lock.withLock { events.map(\.0) } }
  }

  @Test func idleRunsOnceAfterTheLaneStaysEmpty() async throws {
    let lanes = SiteLanes()
    let clock = Clock()
    let idle = SiteLanes.Idle(after: 0.2) { early in clock.mark(early ? "idle-early" : "idle") }
    try await lanes.run("s", pace: 0, label: "list", admit: nil, idle: idle) { clock.mark("call") }
    let end = Date()
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(clock.names == ["call"])
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(clock.names == ["call", "idle"])
    let gap = try #require(clock.time("idle")).timeIntervalSince(end)
    #expect(gap >= 0.2, "呼び出しの終わりから \(gap) 秒で片付けた")
  }

  @Test func callsWithinTheDelayPostponeIdle() async throws {
    let lanes = SiteLanes()
    let clock = Clock()
    let idle = SiteLanes.Idle(after: 0.25) { early in clock.mark(early ? "idle-early" : "idle") }
    for i in 0 ..< 3 {
      if i > 0 { try await Task.sleep(nanoseconds: 150_000_000) }
      try await lanes.run("s", pace: 0, label: "list", admit: nil, idle: idle) { clock.mark("call\(i)") }
    }
    let end = Date()
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(clock.names == ["call0", "call1", "call2", "idle"])
    let gap = try #require(clock.time("idle")).timeIntervalSince(end)
    #expect(gap >= 0.25, "最後の呼び出しの終わりから \(gap) 秒で片付けた")
  }

  @Test func queuedCallsRunBeforeIdle() async throws {
    let lanes = SiteLanes()
    let clock = Clock()
    let idle = SiteLanes.Idle(after: 0.05) { early in clock.mark(early ? "idle-early" : "idle") }
    let first = Task { @MainActor in
      try await lanes.run("s", pace: 0, label: "list", admit: nil, idle: idle) {
        clock.mark("a")
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    let second = Task { @MainActor in
      try await lanes.run("s", pace: 0, label: "list", admit: nil, idle: idle) {
        clock.mark("b-start")
        try await Task.sleep(nanoseconds: 200_000_000)
        clock.mark("b-end")
      }
    }
    try await first.value
    try await second.value
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(clock.names == ["a", "b-start", "b-end", "idle"])
    let gap = try #require(clock.time("idle")).timeIntervalSince(try #require(clock.time("b-end")))
    #expect(gap >= 0.05, "待っていた呼び出しの終わりから \(gap) 秒で片付けた")
  }

  @Test func aCallArrivingDuringIdleWaitsUntilItFinishes() async throws {
    let lanes = SiteLanes()
    let clock = Clock()
    let idle = SiteLanes.Idle(after: 0.05) { _ in
      clock.mark("idle-start")
      do {
        try await Task.sleep(nanoseconds: 300_000_000)
        clock.mark("idle-end")
      } catch {
        clock.mark("idle-cancelled")
      }
    }
    try await lanes.run("s", pace: 0, label: "list", admit: nil, idle: idle) { clock.mark("call0") }
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(clock.names == ["call0", "idle-start"])
    try await lanes.run("s", pace: 0, label: "list", admit: nil, idle: nil) { clock.mark("call1") }
    #expect(clock.names == ["call0", "idle-start", "idle-end", "call1"])
  }

  @Test func idleDoesNotMovePace() async throws {
    let lanes = SiteLanes()
    let clock = Clock()
    let idle = SiteLanes.Idle(after: 0.05) { early in clock.mark(early ? "idle-early" : "idle") }
    try await lanes.run("s", pace: 0.3, label: "list", admit: nil, idle: idle) { clock.mark("call0") }
    try await Task.sleep(nanoseconds: 150_000_000)
    try await lanes.run("s", pace: 0.3, label: "list", admit: nil, idle: idle) { clock.mark("call1") }
    #expect(clock.names == ["call0", "idle", "call1"])
    // pace は片付けの終わりではなく、前の呼び出しの終わりから数える。
    let gap = try #require(clock.time("call1")).timeIntervalSince(try #require(clock.time("call0")))
    #expect(gap >= 0.3 && gap < 0.45, "前の呼び出しから \(gap) 秒で始まった")
  }

  @Test func idleCanRunEarlyOnlyOnce() async throws {
    let lanes = SiteLanes()
    let clock = Clock()
    let idle = SiteLanes.Idle(after: 0.3) { early in clock.mark(early ? "idle-early" : "idle") }
    try await lanes.run("s", pace: 0, label: "list", admit: nil, idle: idle) { clock.mark("call") }
    #expect(lanes.idleSites() == ["s"])
    await lanes.runIdleNow("s")
    #expect(clock.names == ["call", "idle-early"])
    #expect(lanes.idleSites().isEmpty)
    // 予約していた時刻が来ても、二度は走らない。
    try await Task.sleep(nanoseconds: 450_000_000)
    #expect(clock.names == ["call", "idle-early"])
  }

  @Test func idleSitesAreOldestFirstAndSkipBusyOnes() async throws {
    let lanes = SiteLanes()
    let idle = SiteLanes.Idle(after: 30) { _ in }
    for id in ["a", "b"] {
      try await lanes.run(id, pace: 0, label: "list", admit: nil, idle: idle) {}
    }
    #expect(lanes.idleSites() == ["a", "b"])
    let busy = Task { @MainActor in
      try await lanes.run("a", pace: 0, label: "list", admit: nil, idle: idle) {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    // 呼び出し中のサイトは片付けの対象にせず、早めに走らせようとしても何もしない。
    #expect(lanes.idleSites() == ["b"])
    await lanes.runIdleNow("a")
    try await busy.value
    #expect(lanes.idleSites() == ["b", "a"])
    for id in ["a", "b"] { await lanes.runIdleNow(id) }
    #expect(lanes.idleSites().isEmpty)
  }

  @Test func hiddenTabsKeepImagesOnlyForSourcesThatReadImageSizes() {
    #expect(SourceRunner.blockedResourceTypes(code: "const src = img.getAttribute('src');") == ["image", "media", "font"])
    #expect(SourceRunner.blockedResourceTypes(code: "width: img.naturalWidth || undefined") == ["media", "font"])
    #expect(SourceRunner.blockedResourceTypes(code: "height: img.naturalHeight") == ["media", "font"])
  }
}
