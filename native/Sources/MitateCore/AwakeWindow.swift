import AppKit
import WebKit

/// 焦点を奪わずにページを動かし続ける窓。隠しタブと、shoot の計測で使う。
/// WebKit は、見えていない窓のページと、アプリの窓がしばらく描き変わらないとき（visually idle）のページを、30〜60 秒で止める。
/// そこで画面の隅の最前面に 1pt のほぼ透明な窓を置き、見せている間はその 1pt を描き変え続ける。ページの大きさは渡した `web` の frame のまま。
@MainActor
public final class AwakeWindow {
  public let window: NSWindow
  /// 見せている間、描き変え続ける 1pt の点
  private let pulse: NSView
  private var timer: Timer?
  private var on = false

  public init(web: WKWebView, screen: NSScreen) {
    let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    holder.addSubview(web)
    pulse = NSView(frame: holder.bounds)
    pulse.wantsLayer = true
    holder.addSubview(pulse, positioned: .above, relativeTo: web)
    let corner = NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY - 1, width: 1, height: 1)
    window = NSWindow(contentRect: corner, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // 透明度 0 の窓の描き変えは、アプリの窓の描き変えとして数えられない。
    window.alphaValue = 0.01
    window.level = .statusBar
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.contentView = holder
  }

  public func show() {
    window.orderFrontRegardless()
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.on.toggle()
        self.pulse.layer?.backgroundColor = self.on ? NSColor.black.cgColor : NSColor.white.cgColor
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  public func hide() {
    timer?.invalidate()
    timer = nil
    window.orderOut(nil)
  }

  public func close() {
    hide()
    window.close()
  }
}
