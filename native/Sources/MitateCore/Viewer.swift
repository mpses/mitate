import Foundation

/// ビューワーの窓が開いてよいページと、token を渡すスクリプト。
public enum ViewerPolicy {
  public enum Decision: Equatable, Sendable {
    case allow
    /// 止めて既定のブラウザで開く
    case openOutside
    /// 止めるだけ
    case block
  }

  /// ビューワーのオリジンと子フレームはそのまま開く。ほかへの遷移と新しい窓は止め、http(s) なら既定のブラウザで開く。
  /// `isMainFrame` は遷移先のフレーム。新しい窓を開く遷移では nil。
  public static func decide(_ url: URL, isMainFrame: Bool?, viewer: URL) -> Decision {
    if sameOrigin(url, viewer) || isMainFrame == false { return .allow }
    return url.scheme == "http" || url.scheme == "https" ? .openOutside : .block
  }

  static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme == b.scheme && a.host == b.host && a.port == b.port
  }

  /// document start に入れるスクリプト。ビューワーのオリジンのページにだけ `window.__MITATE__ = { token }` を置く。
  public static func tokenScript(viewer: URL, token: String) -> String {
    let origin = "\(viewer.scheme ?? "http")://\(viewer.host ?? "")\(viewer.port.map { ":\($0)" } ?? "")"
    return """
      if (location.origin === \(jsString(origin))) {
        window.__MITATE__ = Object.freeze({ token: \(jsString(token)) });
      }
      """
  }

  /// ビューワーが拾われなかった例外と reject を送る WKScriptMessageHandler の名前。送る形は `web/src/failure.ts` の FailureMessage。
  public static let failureHandler = "mitateFailure"

  /// FailureMessage（`{ kind, message, stack? }`）をログの 1 件にする。
  public static func failureLine(_ body: Any) -> String {
    guard let fields = body as? [String: Any], let kind = fields["kind"] as? String, let message = fields["message"] as? String else {
      return "viewer: 形の違う失敗の報告 \(body)"
    }
    let stack = (fields["stack"] as? String).map { "\n\($0)" } ?? ""
    return "viewer: \(kind) \(message)\(stack)"
  }

  /// タイルのドラッグを始めたことを知らせる WKScriptMessageHandler の名前。送る形は `web/src/drag.ts` の `{ ids }` で、空の配列はドラッグが終わった知らせ。
  public static let dragHandler = "mitateDrag"

  public static func dragIds(_ body: Any) -> [String]? {
    (body as? [String: Any])?["ids"] as? [String]
  }

  static func jsString(_ text: String) -> String {
    // 文字列 1 つの JSON 化は失敗しない。
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
  }
}
