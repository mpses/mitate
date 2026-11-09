import Foundation
import JavaScriptCore

public struct SourceMeta: Codable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let home: URL
  public let loginURL: URL?
  public let canList: Bool
  public let canSearch: Bool
  /// 同じサイトへの呼び出しの間隔（秒）。前の呼び出しの終わりから数える
  public let pace: TimeInterval
}

/// サイト 1 件の JS。ファイル名（拡張子なし）が source の id になる。
public struct SourceFile: Sendable {
  /// `defineSource` で `pace` を省いたときの間隔（ミリ秒）
  public static let defaultPaceMs: Double = 1000

  public let meta: SourceMeta
  public let code: String
  public let file: URL

  public static func load(_ file: URL) throws -> SourceFile {
    let code = try String(contentsOf: file, encoding: .utf8)
    let id = file.deletingPathExtension().lastPathComponent
    return SourceFile(meta: try readMeta(id: id, code: code), code: code, file: file)
  }

  /// ディレクトリ内の `*.js` をすべて読む。`_` で始まるファイルは対象外。
  public static func loadAll(in dir: URL) throws -> [SourceFile] {
    try files(in: dir).map(load)
  }

  /// 読み込む対象のファイル。1 件ずつ読んで失敗をサイトごとに扱うときに使う。
  public static func files(in dir: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "js" && !$0.lastPathComponent.hasPrefix("_") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// DOM の無い JavaScriptCore で評価し、関数は呼ばずに宣言だけを読む。
  static func readMeta(id: String, code: String) throws -> SourceMeta {
    guard let ctx = JSContext() else { throw SourceError.invalid(id, "JSContext を作れない") }
    var exception: String?
    ctx.exceptionHandler = { _, value in exception = value?.toString() }
    ctx.evaluateScript("var __def = null; function defineSource(d) { __def = d; }")
    ctx.evaluateScript(code)
    if let exception { throw SourceError.invalid(id, "読み込みで例外: \(exception)") }
    let json = ctx.evaluateScript("""
      __def && JSON.stringify({
        name: __def.name,
        home: __def.home,
        login: __def.login ? __def.login.url : null,
        loginCheck: !!(__def.login && typeof __def.login.check === 'function'),
        list: typeof __def.list === 'function',
        search: typeof __def.search === 'function',
        pace: __def.pace === undefined ? null : __def.pace,
      })
      """)
    guard let text = json?.toString(), text != "null", text != "undefined", let data = text.data(using: .utf8) else {
      throw SourceError.invalid(id, "defineSource が呼ばれていない")
    }
    struct Decl: Decodable { let name: String?; let home: String?; let login: String?; let loginCheck: Bool; let list: Bool; let search: Bool; let pace: Double? }
    let decl: Decl
    do {
      decl = try JSONDecoder().decode(Decl.self, from: data)
    } catch {
      throw SourceError.invalid(id, "宣言の形が違う（pace は数値のミリ秒）: \(error)")
    }
    guard let name = decl.name, !name.isEmpty else { throw SourceError.invalid(id, "name が無い") }
    guard let homeText = decl.home, isHTTP(homeText), let home = URL(string: homeText) else { throw SourceError.invalid(id, "home が絶対 URL ではない") }
    var loginURL: URL?
    if let login = decl.login {
      guard isHTTP(login), let url = URL(string: login) else { throw SourceError.invalid(id, "login.url が絶対 URL ではない") }
      guard decl.loginCheck else { throw SourceError.invalid(id, "login に check() が無い") }
      loginURL = url
    }
    guard decl.list || decl.search else { throw SourceError.invalid(id, "list と search のどちらも無い") }
    let paceMs = decl.pace ?? SourceFile.defaultPaceMs
    guard paceMs.isFinite, paceMs >= 0 else { throw SourceError.invalid(id, "pace が 0 以上のミリ秒ではない: \(paceMs)") }
    return SourceMeta(id: id, name: name, home: home, loginURL: loginURL, canList: decl.list, canSearch: decl.search, pace: paceMs / 1000)
  }
}

public enum SourceError: Error, CustomStringConvertible {
  case invalid(String, String)
  case script(String, String)
  case navigation(String, String)
  case timeout(String, String)

  public var description: String {
    switch self {
    case let .invalid(id, m): "\(id): \(m)"
    case let .script(id, m): "\(id): JS の実行に失敗: \(m)"
    case let .navigation(id, m): "\(id): ページを開けない: \(m)"
    case let .timeout(id, m): "\(id): 時間切れ: \(m)"
    }
  }
}
