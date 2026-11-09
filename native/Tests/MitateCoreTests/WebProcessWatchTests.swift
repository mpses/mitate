import Foundation
import Testing
@testable import MitateCore

private let limits = WebProcessWatch.Limits(footprint: 1000, busyShare: 0.9, busyRounds: 3, interval: 30)
private let second: UInt64 = 1_000_000_000

private func round(_ samples: [WebProcessWatch.Sample], state: inout WebProcessWatch.State, elapsed: TimeInterval = 30) -> [pid_t] {
  WebProcessWatch.judge(samples, elapsed: elapsed, limits: limits, state: &state).map(\.pid)
}

@Test func メモリが上限を超えたものはすぐ止める() {
  var state = WebProcessWatch.State()
  #expect(round([.init(pid: 1, cpu: 0, footprint: 1001), .init(pid: 2, cpu: 0, footprint: 1000)], state: &state) == [1])
}

@Test func CPUを回し続けた回数が続いたら止める() {
  var state = WebProcessWatch.State()
  #expect(round([.init(pid: 1, cpu: 0, footprint: 0)], state: &state).isEmpty)
  #expect(round([.init(pid: 1, cpu: 29 * second, footprint: 0)], state: &state).isEmpty)
  #expect(round([.init(pid: 1, cpu: 58 * second, footprint: 0)], state: &state).isEmpty)
  #expect(round([.init(pid: 1, cpu: 87 * second, footprint: 0)], state: &state) == [1])
}

@Test func 落ち着いた回があれば数え直す() {
  var state = WebProcessWatch.State()
  _ = round([.init(pid: 1, cpu: 0, footprint: 0)], state: &state)
  _ = round([.init(pid: 1, cpu: 29 * second, footprint: 0)], state: &state)
  _ = round([.init(pid: 1, cpu: 58 * second, footprint: 0)], state: &state)
  #expect(round([.init(pid: 1, cpu: 60 * second, footprint: 0)], state: &state).isEmpty)
  #expect(round([.init(pid: 1, cpu: 89 * second, footprint: 0)], state: &state).isEmpty)
  #expect(round([.init(pid: 1, cpu: 118 * second, footprint: 0)], state: &state).isEmpty)
  #expect(round([.init(pid: 1, cpu: 147 * second, footprint: 0)], state: &state) == [1])
}

@Test func 見回りが遅れたら実際にたった時間で割る() {
  var state = WebProcessWatch.State()
  _ = round([.init(pid: 1, cpu: 0, footprint: 0)], state: &state)
  // 60 秒たって CPU 30 秒なら半分しか使っていない
  for cpu in [30, 60, 90] as [UInt64] {
    #expect(round([.init(pid: 1, cpu: cpu * second, footprint: 0)], state: &state, elapsed: 60).isEmpty)
  }
}

@Test func いなくなったプロセスの記録は捨てる() {
  var state = WebProcessWatch.State()
  _ = round([.init(pid: 1, cpu: 0, footprint: 0)], state: &state)
  _ = round([.init(pid: 1, cpu: 29 * second, footprint: 0)], state: &state)
  _ = round([.init(pid: 1, cpu: 58 * second, footprint: 0)], state: &state)
  _ = round([], state: &state)
  // 同じ pid が使い回されても、前のプロセスの回数を引き継がない
  #expect(round([.init(pid: 1, cpu: 0, footprint: 0)], state: &state).isEmpty)
  #expect(round([.init(pid: 1, cpu: 29 * second, footprint: 0)], state: &state).isEmpty)
}

@Test func launchctlの出力から動いているWebContentだけを拾う() {
  let text = """
    pid/42934 = {
    \tservices = {
    \t\t   42991      - \tcom.apple.WebKit.GPU.5118F07F-F83F-4F4E-8F31-D08642CA5C98
    \t\t       0      - \tcom.apple.WebKit.WebContent
    \t\t   42994      - \tcom.apple.WebKit.WebContent.206C0AD6-28E8-4014-A6F0-BF17C620EBC6
    \t\t   43003      - \tcom.apple.WebKit.WebContent.306C0AD6-28E8-4014-A6F0-BF17C620EBC7
    \t\t   42993      - \tcom.apple.WebKit.Networking.5F2F65E4-063D-4006-B5E8-C274473A4AF7
    \t}
    \tendpoints = {
    \t\t   99999      - \tcom.apple.WebKit.WebContent.not-a-service
    \t}
    }
    """
  #expect(WebProcessWatch.parseWebContent(text) == [42994, 43003])
}

@Test func 自分のプロセスのCPU時間とメモリを読める() throws {
  let first = try #require(WebProcessWatch.sample(getpid()))
  var spin = 0
  for i in 0 ..< 5_000_000 { spin &+= i }
  #expect(spin != 0)
  let second = try #require(WebProcessWatch.sample(getpid()))
  #expect(second.cpu > first.cpu)
  #expect(first.footprint > 0)
}
