import Foundation

public enum PathError: Error, CustomStringConvertible {
  case missing(String)
  case unusable(String, Error)

  public var description: String {
    switch self {
    case let .missing(m): m
    case let .unusable(path, error): "\(path) を使えない: \(error.localizedDescription)"
    }
  }
}

/// データの置き場。`MITATE_HOME`、無ければ `~/Library/Application Support/Mitate`。
public struct Paths: Sendable {
  public let home: URL

  public var library: URL { home.appendingPathComponent("library.sqlite") }
  public var thumbs: URL { home.appendingPathComponent("thumbs", isDirectory: true) }
  public var icons: URL { home.appendingPathComponent("icons", isDirectory: true) }
  public var userSources: URL { home.appendingPathComponent("sources", isDirectory: true) }
  public var models: URL { home.appendingPathComponent("models", isDirectory: true) }
  public var serverInfo: URL { home.appendingPathComponent("server.json") }

  public init(home: URL) {
    self.home = home
  }

  public static func resolveHome(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Paths {
    let home: URL
    if let custom = environment["MITATE_HOME"] {
      guard !custom.isEmpty else { throw PathError.missing("MITATE_HOME が空") }
      home = URL(fileURLWithPath: custom, isDirectory: true)
    } else {
      guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw PathError.missing("Application Support の場所を得られない")
      }
      home = support.appendingPathComponent("Mitate", isDirectory: true)
    }
    return Paths(home: home)
  }

  /// アプリ本体が使うディレクトリをすべて作る。
  public func prepare() throws {
    for dir in [home, thumbs, icons, userSources, models] {
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      } catch {
        throw PathError.unusable(dir.path, error)
      }
    }
  }

  public func thumbFile(key: String) -> URL {
    thumbs.appendingPathComponent(String(key.prefix(2)), isDirectory: true).appendingPathComponent("\(key).jpg")
  }

  public func iconFile(source: String) -> URL {
    icons.appendingPathComponent("\(source).png")
  }
}

/// 同梱のリソース（サイト用 JS、ビューワー、埋め込みモデルの目録）。`.app` の中なら Resources、外なら `MITATE_RESOURCES`。
public struct Resources: Sendable {
  public let root: URL
  public var sources: URL { root.appendingPathComponent("sources", isDirectory: true) }
  public var web: URL { root.appendingPathComponent("web", isDirectory: true) }
  /// `apps/mitate/models.json` の写し
  public var models: URL { root.appendingPathComponent("models.json") }

  public init(root: URL) {
    self.root = root
  }

  public static func resolve(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Resources {
    let root: URL
    if bundle.bundleURL.pathExtension == "app" {
      guard let url = bundle.resourceURL else { throw PathError.missing("\(bundle.bundleURL.path) に Resources が無い") }
      root = url
    } else {
      guard let custom = environment["MITATE_RESOURCES"], !custom.isEmpty else {
        throw PathError.missing(".app の外で動かすときは MITATE_RESOURCES に sources/、web/、models.json を持つディレクトリを指定する")
      }
      root = URL(fileURLWithPath: custom, isDirectory: true)
    }
    let resources = Resources(root: root)
    for dir in [resources.sources, resources.web] {
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
        throw PathError.missing("\(dir.path) が無い")
      }
    }
    guard FileManager.default.fileExists(atPath: resources.models.path) else { throw PathError.missing("\(resources.models.path) が無い") }
    return resources
  }
}

/// 埋め込みモデルの目録（models.json）のうち、アプリが読むところ。取得と照合は `scripts/models.mjs` が行う。
public struct ModelManifest: Decodable, Sendable {
  /// `<データの置き場>/models/` の下のディレクトリ名
  public let dir: String

  public static func load(_ file: URL) throws -> ModelManifest {
    let manifest: ModelManifest
    do {
      manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: file))
    } catch {
      throw PathError.unusable(file.path, error)
    }
    guard !manifest.dir.isEmpty, !manifest.dir.contains("/"), !manifest.dir.hasPrefix(".") else {
      throw PathError.missing("\(file.path) の dir がディレクトリ名ではない: \(manifest.dir)")
    }
    return manifest
  }
}
