import AppKit
import Foundation
import MitateCore
import WebKit

/// アプリと同じ WKWebView でページを開き、JS で操作してから画面を PNG に撮る。ビューワーの見た目の確認と、長い操作の間のメモリの計測に使う。
/// `--server` はアプリのビューワーと同じ設定（token、操作なしの動画の再生、ディスクに置く置き場）で開き、`--visible` は AwakeWindow で描画・タイマー・動画を止めずに動かす。
/// ページの JS は `window.webkit.messageHandlers.shootLog.postMessage(text)` で、途中経過を時刻付きで標準エラーへ出せる。
enum Shoot {
  static let usage = "Mitate shoot <url> <out.png> [--size 1440x900] [--wait 1.5] [--js <script>]... [--js-file <path>]... [--server <server.json>] [--visible]"
  /// `--server` で使う置き場。開発用のアプリの置き場（.default()）と分け、実行をまたいで使い回す
  static let viewerStore = UUID(uuidString: "6D4B1F0E-5C1A-4E8B-9D21-3B7F5A2C8E10")!

  @MainActor
  static func run(_ args: [String]) async -> Int32 {
    var rest = args[...]
    guard let urlText = rest.popFirst(), let url = URL(string: urlText), let outPath = rest.popFirst() else {
      fputs("usage: \(usage)\n", stderr)
      return 64
    }
    var size = NSSize(width: 1440, height: 900)
    var wait = 1.5
    var scripts: [String] = []
    var serverPath: String?
    var visible = false
    while let flag = rest.popFirst() {
      switch flag {
      case "--size":
        let parts = (rest.popFirst() ?? "").split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
      case "--wait": wait = rest.popFirst().flatMap(Double.init) ?? wait
      case "--js": if let js = rest.popFirst() { scripts.append(js) }
      case "--js-file":
        guard let path = rest.popFirst() else {
          fputs("--js-file にパスが無い\n", stderr)
          return 64
        }
        do {
          scripts.append(try String(contentsOfFile: path, encoding: .utf8))
        } catch {
          fputs("\(path) を読めない: \(error)\n", stderr)
          return 1
        }
      case "--server":
        guard let path = rest.popFirst() else {
          fputs("--server に server.json のパスが無い\n", stderr)
          return 64
        }
        serverPath = path
      case "--visible": visible = true
      default:
        fputs("unknown flag \(flag)\n", stderr)
        return 64
      }
    }

    let config: WKWebViewConfiguration
    if let serverPath {
      // 開発用のアプリが書いた server.json の token を、アプリのビューワーと同じ設定で入れる。
      let info: ServerInfo
      do {
        info = try JSONDecoder().decode(ServerInfo.self, from: Data(contentsOf: URL(fileURLWithPath: serverPath)))
      } catch {
        fputs("\(serverPath) を読めない: \(error)\n", stderr)
        return 1
      }
      let origin = ViewerWindow.origin(port: info.port)
      guard url.host == origin.host, url.port == origin.port else {
        fputs("\(url.absoluteString) は \(serverPath) のビューワー（\(origin.absoluteString)）ではない\n", stderr)
        return 64
      }
      config = ViewerWindow.configuration(origin: origin, token: info.token, dataStore: WKWebsiteDataStore(forIdentifier: viewerStore))
    } else {
      config = SourceRunner.configuration(dataStore: .nonPersistent())
    }
    config.userContentController.add(PageLog(), name: PageLog.name)

    let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
    var awake: AwakeWindow?
    var activity: NSObjectProtocol?
    if visible {
      guard let screen = NSScreen.screens.first else {
        fputs("画面が無いので --visible の窓を置けない\n", stderr)
        return 1
      }
      // prohibited のアプリは窓を出さない決まりなので、焦点を取らない accessory にする。
      NSApp.setActivationPolicy(.accessory)
      // アプリの窓と同じく、App Nap で間引かれないようにする。
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "shoot のページを動かし続ける")
      // 画面のロック中もロック画面に覆われたページを止めないよう、窓の重なりを見ない（公開の手段が無いので SPI）。
      web.setValue(false, forKey: "windowOcclusionDetectionEnabled")
      awake = AwakeWindow(web: web, screen: screen)
      awake?.show()
    } else {
      let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -40000, y: -40000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = web
      window.orderBack(nil)
    }
    defer {
      awake?.close()
      activity.map(ProcessInfo.processInfo.endActivity)
    }

    let loaded = Loader()
    web.navigationDelegate = loaded
    web.load(URLRequest(url: url))
    guard await loaded.wait(timeout: 30) else {
      fputs("ページを読み込めない: \(url)\n", stderr)
      return 1
    }
    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    for script in scripts {
      do {
        let result = try await web.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
        if let result { print("js → \(result)") }
      } catch {
        let ns = error as NSError
        fputs("js が失敗: \(ns.userInfo["WKJavaScriptExceptionMessage"] ?? ns.localizedDescription)\n", stderr)
        return 1
      }
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    let snapshotConfig = WKSnapshotConfiguration()
    snapshotConfig.rect = NSRect(origin: .zero, size: size)
    guard let image = try? await web.takeSnapshot(configuration: snapshotConfig),
          let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else {
      fputs("撮影に失敗\n", stderr)
      return 1
    }
    do {
      try png.write(to: URL(fileURLWithPath: outPath))
    } catch {
      fputs("書き込めない: \(error)\n", stderr)
      return 1
    }
    print("wrote \(outPath)")
    return 0
  }

  /// ページの JS が送った途中経過を、時刻付きでログへ出す。
  @MainActor
  final class PageLog: NSObject, WKScriptMessageHandler {
    static let name = "shootLog"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      log("shoot \(Timestamp.string()) \(message.body)")
    }
  }

  @MainActor
  final class Loader: NSObject, WKNavigationDelegate {
    private var done = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func wait(timeout: TimeInterval) async -> Bool {
      if done { return true }
      return await withCheckedContinuation { continuation in
        waiter = continuation
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
      }
    }

    private func finish(_ ok: Bool) {
      if ok { done = true }
      waiter?.resume(returning: ok)
      waiter = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
  }
}
