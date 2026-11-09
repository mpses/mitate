import AppKit
import Carbon.HIToolbox
import Foundation
import MitateCore
import WebKit

/// 引数なしで起動したときの Mac アプリ。窓を閉じても索引と HTTP は動き続ける。
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
  private var paths: Paths?
  private var engine: Engine?
  private var server: Server?
  private var viewer: ViewerWindow?
  private var hotKey: HotKey?
  private var logins: [String: LoginWindow] = [:]
  private var signals: [DispatchSourceSignal] = []
  private var activity: NSObjectProtocol?
  private let watchdog = WebProcessWatchdog()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = Self.mainMenu(reload: #selector(reloadViewer(_:)), target: self)
    for sig in [SIGTERM, SIGINT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { NSApp.terminate(nil) }
      source.resume()
      signals.append(source)
    }
    Task { @MainActor in
      do {
        try await self.launch()
      } catch {
        fputs("Mitate を起動できない: \(error)\n", stderr)
        exit(1)
      }
    }
  }

  private func launch() async throws {
    // 窓を閉じていても索引の取得と HTTP の応答を同じ速さで続けるので、App Nap で間引かれないようにする。
    activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "索引の取得と HTTP の応答")
    let paths = try Paths.resolveHome()
    let resources = try Resources.resolve()
    try paths.prepare()
    if let other = try await AppClient.running(paths), other.pid != getpid() {
      throw ClientError("別の Mitate（pid \(other.pid)）が \(paths.home.path) で動いている")
    }
    self.paths = paths
    let engine = try Engine(paths: paths, resources: resources, embedder: try await Self.loadEmbedder(paths: paths, resources: resources))
    self.engine = engine
    let token = try ServerFile.token()
    let actions = HTTPActions(
      openLogin: { id in await MainActor.run { self.openLogin(id) } },
      openURL: { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
    )
    let (server, port) = try await Server.start { port in
      HTTPRouter(engine: engine, port: port, token: token, web: resources.web, actions: actions)
    }
    self.server = server
    try ServerFile.write(ServerInfo(port: port, token: token, pid: getpid()), to: paths.serverInfo)
    log("http: http://127.0.0.1:\(port)/ で待ち受け（\(paths.serverInfo.path)）")

    let dragOut = DragOut.temporary()
    let viewer = ViewerWindow(port: port, token: token) { ids in Self.export(ids, engine: engine, to: dragOut) }
    self.viewer = viewer
    viewer.show()
    NSApp.activate()
    watchdog.start()

    // 登録の途中で失敗しても、入れたイベントハンドラーが指す先を残しておく。
    let hotKey = HotKey { [weak self] in self?.summon() }
    self.hotKey = hotKey
    do {
      try hotKey.register()
    } catch {
      fputs("ホットキー ⌥Space を登録できない（\(error)）。窓は Dock から出す\n", stderr)
    }
    try await engine.start()
  }

  /// models.json の dir にモデルがあれば読む。ディレクトリが無ければ取り方を標準エラーに出し、埋め込みなしで動く。
  private static func loadEmbedder(paths: Paths, resources: Resources) async throws -> Embedder? {
    let dir = paths.models.appendingPathComponent(try ModelManifest.load(resources.models).dir, isDirectory: true)
    let fetch = "node apps/mitate/scripts/models.mjs \"\(paths.home.path)\""
    guard FileManager.default.fileExists(atPath: dir.path) else {
      fputs("埋め込みモデルが無い: \(dir.path)\n取るには: \(fetch)\n埋め込みなしで動く（検索は全文検索だけ、similar は 503）\n", stderr)
      return nil
    }
    let started = Date()
    // 34MB の tokenizer.json を読むので、メインスレッドの外で作る。
    let embedder: SigLIPEmbedder
    do {
      embedder = try await Task.detached(priority: .utility) { try SigLIPEmbedder(directory: dir) }.value
    } catch {
      throw ClientError("埋め込みモデルを読めない（\(error)）。取り直すには: \(fetch)")
    }
    log("embedder \(embedder.model): \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒で読んだ（\(dir.path)）")
    return embedder
  }

  /// ドラッグする Shot をファイルにする。画像はまず手元のサムネイルで渡し、受け手が読むまでに間に合えば長辺 1568px の画像に置き換える。
  private static func export(_ ids: [String], engine: Engine, to out: DragOut) -> [URL] {
    let written: DragOut.Written
    do {
      written = try out.write(try engine.library.views(ids), thumb: engine.mediaFile(key:))
    } catch {
      log("drag: ファイルを書けない \(error)")
      return []
    }
    if !written.missing.isEmpty {
      log("drag: サムネイルがまだ無いので渡さない \(written.missing.joined(separator: ", "))")
    }
    for (view, file) in written.files where view.kind != .text {
      Task.detached(priority: .userInitiated) {
        do {
          try await engine.view(id: view.id).write(to: file, options: .atomic)
        } catch {
          log("drag: \(view.id) を大きな画像に置き換えられない \(error)")
        }
      }
    }
    return written.files.map(\.file)
  }

  /// ホットキー。窓を前に出し、ビューワーの検索欄に焦点を移す。
  private func summon() {
    // ホットキーは別のアプリが前にあるときに押すので、譲られるのを待つ activate() では前に出られない。
    NSApp.activate(ignoringOtherApps: true)
    viewer?.show()
    viewer?.focusSearch()
  }

  @objc private func reloadViewer(_ sender: Any?) {
    viewer?.reload()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    viewer?.show()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    server?.stop()
    if let paths { ServerFile.remove(paths.serverInfo, pid: getpid()) }
  }

  // MARK: - ログイン

  private func openLogin(_ id: String) {
    if let existing = logins[id] {
      existing.window.makeKeyAndOrderFront(nil)
      return
    }
    guard let engine, let source = engine.source(id), let url = source.meta.loginURL else {
      log("login \(id): ログイン画面を持たないサイト")
      return
    }
    let login = LoginWindow(source: source, url: url, engine: engine) { [weak self] in self?.logins[id] = nil }
    logins[id] = login
    NSApp.activate()
    login.window.makeKeyAndOrderFront(nil)
  }

  // MARK: - メニュー

  static func mainMenu(reload: Selector, target: AnyObject) -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let menu = NSMenu(title: title)
      for item in items { menu.addItem(item) }
      let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      holder.submenu = menu
      main.addItem(holder)
      return menu
    }
    func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      return item
    }
    _ = submenu("Mitate", [
      item("Mitate について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
      .separator(),
      item("Mitate を隠す", #selector(NSApplication.hide(_:)), "h"),
      .separator(),
      item("Mitate を終了", #selector(NSApplication.terminate(_:)), "q"),
    ])
    _ = submenu("編集", [
      item("取り消す", Selector(("undo:")), "z"),
      item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      item("カット", #selector(NSText.cut(_:)), "x"),
      item("コピー", #selector(NSText.copy(_:)), "c"),
      item("ペースト", #selector(NSText.paste(_:)), "v"),
      item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
    ])
    let reloadItem = item("再読み込み", reload, "r")
    reloadItem.target = target
    _ = submenu("表示", [reloadItem])
    let window = submenu("ウインドウ", [
      item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("拡大／縮小", #selector(NSWindow.performZoom(_:)), ""),
      item("閉じる", #selector(NSWindow.performClose(_:)), "w"),
      .separator(),
      item("すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:)), ""),
    ])
    NSApp.windowsMenu = window
    return main
  }
}

// MARK: - ビューワーの窓

/// `http://127.0.0.1:<port>/` を開く WKWebView の窓。token はビューワーのオリジンのページにだけ渡す。
@MainActor
final class ViewerWindow: NSObject, WKNavigationDelegate, WKUIDelegate {
  static let dragHeight: CGFloat = 28

  let window: NSWindow
  private let web: ViewerWebView
  private let origin: URL

  /// `export` はドラッグする Shot の id を受け、ほかのアプリへ渡すファイルを返す。
  init(port: Int, token: String, export: @escaping ([String]) -> [URL]) {
    origin = Self.origin(port: port)
    web = ViewerWebView(frame: .zero, configuration: Self.configuration(origin: origin, token: token, dataStore: .default()))
    web.export = export
    web.configuration.userContentController.add(DragMessages(viewer: origin, web: web), name: ViewerPolicy.dragHandler)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    super.init()
    window.title = "Mitate"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.minSize = NSSize(width: 640, height: 480)
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("MitateViewer")

    let container = NSView()
    web.translatesAutoresizingMaskIntoConstraints = false
    let bar = DragBar()
    bar.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(web)
    container.addSubview(bar, positioned: .above, relativeTo: web)
    NSLayoutConstraint.activate([
      web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      web.topAnchor.constraint(equalTo: container.topAnchor),
      web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bar.topAnchor.constraint(equalTo: container.topAnchor),
      bar.heightAnchor.constraint(equalToConstant: Self.dragHeight),
    ])
    window.contentView = container
    // 窓の first responder が WKWebView でないと、ページの入力欄に焦点があっても打鍵がページへ届かない。
    window.initialFirstResponder = web
    web.navigationDelegate = self
    web.uiDelegate = self
    web.load(URLRequest(url: origin))
  }

  static func origin(port: Int) -> URL {
    URL(string: "http://127.0.0.1:\(port)/")!
  }

  /// ビューワーの WKWebView の設定。shoot の `--server` も同じ設定で開く。
  static func configuration(origin: URL, token: String, dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
    let config = SourceRunner.configuration(dataStore: dataStore)
    // 壁の動画はホバーで muted 再生し、焦点表示ではクリックの後に再生するので、再生の前に操作を求めない。
    config.mediaTypesRequiringUserActionForPlayback = []
    let script = ViewerPolicy.tokenScript(viewer: origin, token: token)
    config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    config.userContentController.add(FailureLog(viewer: origin), name: ViewerPolicy.failureHandler)
    return config
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
  }

  func reload() {
    web.load(URLRequest(url: origin))
  }

  func focusSearch() {
    window.makeFirstResponder(web)
    web.evaluateJavaScript("window.dispatchEvent(new Event('mitate:focus-search'))") { _, error in
      if let error { log("viewer: mitate:focus-search を送れない \(error)") }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
    let decision = ViewerPolicy.decide(url, isMainFrame: navigationAction.targetFrame?.isMainFrame, viewer: origin)
    decisionHandler(decision == .allow ? .allow : .cancel)
    follow(decision, url)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url { follow(ViewerPolicy.decide(url, isMainFrame: nil, viewer: origin), url) }
    return nil
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    log("viewer: WebContent のプロセスが落ちたので読み直す")
    reload()
  }

  private func follow(_ decision: ViewerPolicy.Decision, _ url: URL) {
    switch decision {
    case .allow: break
    case .openOutside:
      log("viewer: \(url.absoluteString) は既定のブラウザで開く")
      NSWorkspace.shared.open(url)
    case .block:
      log("viewer: \(url.absoluteString) への遷移を止めた")
    }
  }
}

/// ビューワーで拾われなかった例外と reject を標準エラーへ出す。ビューワーのオリジンの main frame からだけ受ける。
@MainActor
final class FailureLog: NSObject, WKScriptMessageHandler {
  private let viewer: URL

  init(viewer: URL) {
    self.viewer = viewer
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.isFromViewer(viewer) else { return }
    log(ViewerPolicy.failureLine(message.body))
  }
}

extension WKScriptMessage {
  /// ビューワーのオリジンの main frame から届いた。
  @MainActor
  func isFromViewer(_ viewer: URL) -> Bool {
    let origin = frameInfo.securityOrigin
    return frameInfo.isMainFrame && origin.protocol == viewer.scheme && origin.host == viewer.host && origin.port == viewer.port
  }
}

// MARK: - ほかのアプリへのドラッグ

/// ページの dragstart が送る、ドラッグする Shot の id を ViewerWebView に渡す。
@MainActor
final class DragMessages: NSObject, WKScriptMessageHandler {
  private let viewer: URL
  private weak var web: ViewerWebView?

  init(viewer: URL, web: ViewerWebView) {
    self.viewer = viewer
    self.web = web
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.isFromViewer(viewer) else { return }
    guard let ids = ViewerPolicy.dragIds(message.body) else {
      log("viewer: 形の違うドラッグの知らせ \(message.body)")
      return
    }
    guard let web else { return }
    if ids.isEmpty, let left = web.outgoing {
      log("drag: \(left.count) 件の Shot をファイルにする前にドラッグが終わった。WebKit が dragImage でドラッグを始めていない")
    }
    web.outgoing = ids.isEmpty ? nil : ids
  }
}

/// ビューワーの WKWebView。タイルのドラッグでは、WebKit が書いた中身（URL の文字列）を Shot のファイルに差し替えて、
/// 端末やエージェントのチャットへそのまま落とせるようにする。
/// この版の WebKit（7624 系）は、ページの dragstart の知らせを届けた後に、通常のドラッグを NSView の dragImage で始める。
@MainActor
class ViewerWebView: WKWebView {
  var outgoing: [String]?
  var export: (([String]) -> [URL])?

  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    _ = Self.dragHook
    super.init(frame: frame, configuration: configuration)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) は使わない")
  }

  /// 差し替えたら true。false なら WebKit のドラッグをそのまま始める。
  private func startFileDrag(image: NSImage, at viewLocation: NSPoint, event: NSEvent, source: AnyObject) -> Bool {
    guard let ids = outgoing, let export else { return false }
    outgoing = nil
    let files = export(ids)
    guard !files.isEmpty, let source = source as? NSDraggingSource else {
      log("drag: \(ids.count) 件の Shot をファイルにできなかったので、URL だけを渡す")
      return false
    }
    // viewLocation は画像の左下。WKWebView は上下が反転しているので、枠の原点は左上になる
    let frame = NSRect(x: viewLocation.x, y: viewLocation.y - image.size.height, width: image.size.width, height: image.size.height)
    let items = files.map { file in
      let item = NSDraggingItem(pasteboardWriter: file as NSURL)
      item.setDraggingFrame(frame, contents: image)
      return item
    }
    beginDraggingSession(with: items, event: event, source: source)
    return true
  }

  /// dragImage は Swift から override できない（unavailable）ので、同じ selector の実装を実行時に足す。
  private static let dragHook: Void = {
    let selector = NSSelectorFromString("dragImage:at:offset:event:pasteboard:source:slideBack:")
    guard let inherited = class_getInstanceMethod(WKWebView.self, selector) else {
      log("drag: WKWebView に \(selector) が無いので、タイルはファイルとしてドラッグできない")
      return
    }
    typealias DragImage = @convention(c) (AnyObject, Selector, NSImage, NSPoint, NSSize, NSEvent, NSPasteboard, AnyObject, Bool) -> Void
    let inheritedDrag = unsafeBitCast(method_getImplementation(inherited), to: DragImage.self)
    let drag: @convention(block) (ViewerWebView, NSImage, NSPoint, NSSize, NSEvent, NSPasteboard, AnyObject, Bool) -> Void = { view, image, at, offset, event, pasteboard, source, slideBack in
      let replaced = MainActor.assumeIsolated { view.startFileDrag(image: image, at: at, event: event, source: source) }
      if !replaced { inheritedDrag(view, selector, image, at, offset, event, pasteboard, source, slideBack) }
    }
    class_addMethod(ViewerWebView.self, selector, imp_implementationWithBlock(drag), method_getTypeEncoding(inherited))
  }()
}

/// 窓の上端に重ねる透明な帯。ドラッグで窓を動かし、ダブルクリックで拡大／縮小する。
final class DragBar: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      window?.performZoom(nil)
    } else {
      window?.performDrag(with: event)
    }
  }
}

// MARK: - ホットキー

/// Carbon の RegisterEventHotKey で ⌥Space を受ける。
@MainActor
final class HotKey {
  private let action: () -> Void
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?

  struct Failure: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) が OSStatus \(status)" }
  }

  init(action: @escaping () -> Void) {
    self.action = action
  }

  func register() throws {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
      guard let userData else { return OSStatus(eventNotHandledErr) }
      let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
      MainActor.assumeIsolated { hotKey.action() }
      return noErr
    }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else { throw Failure(step: "InstallEventHandler", status: status) }
    // 'MTAT'
    let id = EventHotKeyID(signature: OSType(0x4D54_4154), id: 1)
    let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
    guard registered == noErr else { throw Failure(step: "RegisterEventHotKey", status: registered) }
  }
}

// MARK: - ログインの窓

/// サイトのログイン画面。4 秒ごとに隠しタブを開き直してログインできたかを確かめ、できたら閉じる。閉じたら `signInChanged` を呼ぶ。
/// 確かめる処理はサイトの列に並ぶので、取得中の呼び出しを途中で切らない。
@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, WKUIDelegate {
  let window: NSWindow
  private let web: WKWebView
  private let source: SourceFile
  private let engine: Engine
  private let onClose: () -> Void
  private var timer: Timer?
  private var checking = false
  private var popups: [(window: NSWindow, web: WKWebView)] = []

  init(source: SourceFile, url: URL, engine: Engine, onClose: @escaping () -> Void) {
    self.source = source
    self.engine = engine
    self.onClose = onClose
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: SourceRunner.configuration(dataStore: .default()))
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = "\(source.meta.name) にログイン"
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.center()
    window.delegate = self
    web.uiDelegate = self
    web.load(URLRequest(url: url))
    timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
  }

  private func check() {
    guard !checking else { return }
    checking = true
    Task { @MainActor in
      defer { self.checking = false }
      do {
        if try await self.engine.runner.signedIn(self.source, reload: true) {
          log("login \(self.source.meta.id): ログインできた")
          self.window.close()
        }
      } catch {
        log("login \(self.source.meta.id): ログイン状態を確かめられない \(error)")
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) === window else { return }
    timer?.invalidate()
    timer = nil
    for popup in popups { popup.window.close() }
    popups.removeAll()
    let id = source.meta.id
    let engine = engine
    Task { await engine.signInChanged(source: id) }
    onClose()
  }

  /// OAuth のポップアップは子の窓として開く。
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    let frame = NSRect(x: 0, y: 0, width: windowFeatures.width?.doubleValue ?? 480, height: windowFeatures.height?.doubleValue ?? 640)
    let child = WKWebView(frame: frame, configuration: configuration)
    child.uiDelegate = self
    let popup = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    popup.isReleasedWhenClosed = false
    popup.contentView = child
    window.addChildWindow(popup, ordered: .above)
    popup.center()
    popup.makeKeyAndOrderFront(nil)
    popups.append((popup, child))
    return child
  }

  func webViewDidClose(_ webView: WKWebView) {
    guard let index = popups.firstIndex(where: { $0.web === webView }) else { return }
    popups.remove(at: index).window.close()
  }
}
