import Darwin
import Foundation

/// アプリが持つ WebKit の WebContent を一定の間隔で見回り、暴走しているものを止める。
/// サイトのページの JS が終わらなくなった WebContent は、隠しタブを閉じた後も CPU 1 本と 1GB 近くを持ち続けることがある。
/// 止めたプロセスは WebKit からは落ちたものに見えるので、ビューワーは読み直し、隠しタブは呼び出しが失敗して閉じる。
public enum WebProcessWatch {
  public struct Limits: Sendable {
    /// これを超えた WebContent はすぐ止める
    public var footprint: UInt64
    /// 見回りの間に CPU 1 本のこの割合より多く使っていたら、その回は回り続けていたとみなす
    public var busyShare: Double
    /// 回り続けていた見回りがこの回数続いたら止める
    public var busyRounds: Int
    /// 見回りの間隔（秒）
    public var interval: TimeInterval

    /// 15 秒ごとに見て、1,200MiB を超えるか、5 分続けて CPU 1 本の半分より多く使っていたら止める。
    /// 回り続けるページでも、Mac が混んでいると 1 回の見回りの間に CPU 1 本の 7 割前後しか得られない
    public static let standard = Limits(footprint: 1200 << 20, busyShare: 0.5, busyRounds: 20, interval: 15)
  }

  public struct Sample: Sendable, Equatable {
    public var pid: pid_t
    /// 起動からの CPU 時間（ナノ秒）
    public var cpu: UInt64
    /// phys_footprint（バイト）
    public var footprint: UInt64
  }

  /// 見回りをまたいで持つもの。pid ごとの前回の CPU 時間と、回り続けていた見回りの回数
  public struct State: Sendable {
    var cpu: [pid_t: UInt64] = [:]
    var busy: [pid_t: Int] = [:]
    public init() {}
  }

  /// 1 回の見回り。前回から `elapsed` 秒たったときの samples から、止める pid と理由を返す。
  /// 前回の CPU 時間が無いプロセスは、その回の回り方を判断しない。
  public static func judge(_ samples: [Sample], elapsed: TimeInterval, limits: Limits, state: inout State) -> [(pid: pid_t, reason: String)] {
    var kills: [(pid: pid_t, reason: String)] = []
    var next = State()
    for sample in samples {
      if sample.footprint > limits.footprint {
        kills.append((sample.pid, "メモリが \(sample.footprint >> 20) MiB（上限 \(limits.footprint >> 20) MiB）"))
        continue
      }
      next.cpu[sample.pid] = sample.cpu
      guard let before = state.cpu[sample.pid], sample.cpu >= before, elapsed > 0 else { continue }
      let share = Double(sample.cpu - before) / 1e9 / elapsed
      guard share > limits.busyShare else { continue }
      let rounds = (state.busy[sample.pid] ?? 0) + 1
      if rounds >= limits.busyRounds {
        kills.append((sample.pid, "CPU を \(Int(limits.interval * Double(rounds))) 秒続けて回している（直近 \(Int(share * 100))%）"))
        next.cpu[sample.pid] = nil
      } else {
        next.busy[sample.pid] = rounds
      }
    }
    state = next
    return kills
  }

  /// `host` の launchd の pid ドメインにある WebKit の WebContent の pid。XPC のプロセスの親は launchd なので、ドメインで見分ける
  public static func webContentPIDs(host: pid_t) throws -> [pid_t] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "pid/\(host)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw WatchError("launchctl print pid/\(host) が \(process.terminationStatus) で終わった") }
    return parseWebContent(String(decoding: data, as: UTF8.self))
  }

  /// `launchctl print pid/<pid>` の services の欄から、動いている WebContent の pid を拾う
  static func parseWebContent(_ text: String) -> [pid_t] {
    guard let start = text.range(of: "services = {") else { return [] }
    let block = text[start.upperBound...].prefix { $0 != "}" }
    return block.split(separator: "\n").compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 3, fields[2].hasPrefix("com.apple.WebKit.WebContent"), let pid = pid_t(fields[0]), pid != 0 else { return nil }
      return pid
    }
  }

  /// CPU 時間と phys_footprint。プロセスが無ければ nil
  public static func sample(_ pid: pid_t) -> Sample? {
    var info = rusage_info_v0()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
    }
    guard status == 0 else { return nil }
    // ri_user_time と ri_system_time は mach の時間の単位
    let ticks = info.ri_user_time + info.ri_system_time
    return Sample(pid: pid, cpu: ticks * UInt64(timebase.numer) / UInt64(timebase.denom), footprint: info.ri_phys_footprint)
  }

  private static let timebase: mach_timebase_info_data_t = {
    var value = mach_timebase_info_data_t()
    mach_timebase_info(&value)
    return value
  }()
}

public struct WatchError: Error, CustomStringConvertible {
  public let description: String
  init(_ description: String) { self.description = description }
}

/// WebProcessWatch を、main thread の外の timer で回す
public final class WebProcessWatchdog: @unchecked Sendable {
  private let limits: WebProcessWatch.Limits
  private let queue = DispatchQueue(label: "org.bakutan.mitate.watchdog", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var state = WebProcessWatch.State()
  private var last: ContinuousClock.Instant?

  public init(limits: WebProcessWatch.Limits = .standard) {
    self.limits = limits
  }

  public func start() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + limits.interval, repeating: limits.interval, leeway: .seconds(5))
    timer.setEventHandler { [weak self] in self?.round() }
    timer.resume()
    self.timer = timer
  }

  private func round() {
    let pids: [pid_t]
    do {
      pids = try WebProcessWatch.webContentPIDs(host: getpid())
    } catch {
      log("watchdog: WebContent を数えられない（\(error)）")
      return
    }
    let now = ContinuousClock.now
    // 混んでいて timer が遅れても、実際にたった時間で割る
    let elapsed = last.map { (now - $0) / .seconds(1) } ?? limits.interval
    last = now
    let samples = pids.compactMap(WebProcessWatch.sample)
    for kill in WebProcessWatch.judge(samples, elapsed: elapsed, limits: limits, state: &state) {
      if Darwin.kill(kill.pid, SIGKILL) == 0 {
        log("watchdog: WebContent \(kill.pid) を止めた（\(kill.reason)）")
      } else {
        log("watchdog: WebContent \(kill.pid) を止められない（errno \(errno)、\(kill.reason)）")
      }
    }
  }
}
