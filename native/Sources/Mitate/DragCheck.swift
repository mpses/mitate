import AppKit
import Foundation
import MitateCore
import WebKit

/// ビューワーのタイルのドラッグが、WebKit の中で Shot のファイルのドラッグに差し替わるかを確かめる。
/// 差し替えは WebKit がドラッグを始める手順に頼っているので、macOS を上げたら流す。
/// マウスの操作は OS へ送らず、画面の外の窓の WKWebView へ直に渡す。ドラッグのセッションは始めず、渡す中身だけを取り出す。
/// URL を渡すと、そのビューワー（`MITATE_API=mock` の dev サーバーなど）の壁の最初のタイルをドラッグする。
enum DragCheck {
  static let usage = "Mitate dragcheck [<viewer url>]"

  private static let page = """
    <!doctype html><body style="margin:0">
    <button id="tile" draggable="true" style="position:absolute;left:20px;top:20px;width:200px;height:120px">tile</button>
    <script>
    document.getElementById("tile").addEventListener("dragstart", (event) => {
      event.dataTransfer.effectAllowed = "copy";
      event.dataTransfer.setData("text/uri-list", "https://example.com/1");
      window.webkit.messageHandlers.\(ViewerPolicy.dragHandler).postMessage({ ids: ["detail:1"] });
    });
    </script>
    """

  @MainActor
  static func run(_ args: [String]) async -> Int32 {
    let viewer = args.first.flatMap(URL.init(string:))
    if !args.isEmpty, viewer?.host == nil {
      fputs("usage: \(usage)\n", stderr)
      return 64
    }
    let origin = viewer.flatMap { URL(string: "/", relativeTo: $0)?.absoluteURL } ?? URL(string: "http://127.0.0.1:9/")!
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mitate-dragcheck.jpg")
    do {
      try Data([0xFF, 0xD8, 0xFF]).write(to: file)
    } catch {
      fputs("FAIL: \(file.path) を書けない \(error)\n", stderr)
      return 1
    }
    defer { try? FileManager.default.removeItem(at: file) }

    let size = NSSize(width: 1280, height: 800)
    let web = CapturingWebView(frame: NSRect(origin: .zero, size: size), configuration: WKWebViewConfiguration())
    var asked: [String]?
    web.export = { ids in
      asked = ids
      return [file]
    }
    web.configuration.userContentController.add(DragMessages(viewer: origin, web: web), name: ViewerPolicy.dragHandler)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -40000, y: -40000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = web
    window.orderBack(nil)
    if let viewer {
      web.load(URLRequest(url: viewer))
    } else {
      web.loadHTMLString(page, baseURL: origin)
    }
    let find = "(() => { const t = document.querySelector('[data-shot-id][draggable=true]'); if (!t || document.readyState !== 'complete') return null; const r = t.getBoundingClientRect(); return [t.dataset.shotId, r.left + r.width / 2, r.top + r.height / 2]; })()"
    var target: [Any]?
    guard await poll(timeout: 20, {
      target = (try? await web.evaluateJavaScript(viewer == nil ? "document.getElementById('tile') ? ['detail:1', 60, 60] : null" : find)) as? [Any]
      return target != nil
    }), let target, let expected = target[0] as? String, let x = target[1] as? Double, let y = target[2] as? Double else {
      fputs("FAIL: ドラッグできるタイルが現れない\n", stderr)
      return 1
    }

    // タイルの中ほどから右へ動かす。窓の座標は左下が原点
    var point = NSPoint(x: x, y: size.height - y)
    web.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: window))
    for _ in 0 ..< 20 {
      try? await Task.sleep(nanoseconds: 20_000_000)
      point.x += 4
      web.mouseDragged(with: mouseEvent(.leftMouseDragged, at: point, in: window))
    }
    guard await poll(timeout: 5, { web.captured != nil }), let items = web.captured else {
      fputs("FAIL: WebKit が dragImage でドラッグを始めなかった（ページの知らせ: \(asked.map { "\($0)" } ?? "届いていない")）\n", stderr)
      return 1
    }
    let urls = items.compactMap { $0.item as? NSURL }.map { $0 as URL }
    guard asked == [expected], urls == [file] else {
      fputs("FAIL: 渡す中身が違う（id: \(asked ?? []), ファイル: \(items.map(\.item))）\n", stderr)
      return 1
    }
    print("PASS: dragstart の id \(asked ?? []) を \(urls.map(\.path)) のドラッグに差し替えた")
    return 0
  }

  @MainActor
  private static func poll(timeout: TimeInterval, _ done: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await done() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
  }

  private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
}

/// ドラッグのセッションを始めず、渡そうとした項目を持っておく。
@MainActor
private final class CapturingWebView: ViewerWebView {
  struct Captured {
    let item: Any
  }

  var captured: [Captured]?
  /// 始めていないセッションは、放すと AppKit がエラーを出すので終わるまで持つ
  private var placeholder: NSDraggingSession?

  override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: NSDraggingSource) -> NSDraggingSession {
    captured = items.map { Captured(item: $0.item) }
    let session = NSDraggingSession()
    placeholder = session
    return session
  }
}
