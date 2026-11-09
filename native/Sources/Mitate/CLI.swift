import Foundation
import MitateCore
import UniformTypeIdentifiers

/// `Mitate search|similar|selection|sync|status`。起動中のアプリへ HTTP で問い合わせる。
enum CLI {
  static let usage = """
    usage:
      Mitate search <query> [--live] [--json] [--limit n]
      Mitate similar <id|image-path> [--json] [--limit n]
      Mitate selection [--json]
      Mitate sync [source]
      Mitate status [--json]
    """

  struct Options {
    var words: [String] = []
    var live = false
    var json = false
    var limit = 20
  }

  static func parse(_ args: [String]) -> Options? {
    var options = Options()
    var rest = args[...]
    while let arg = rest.popFirst() {
      switch arg {
      case "--live": options.live = true
      case "--json": options.json = true
      case "--limit":
        guard let n = rest.popFirst().flatMap(Int.init), n > 0 else { return nil }
        options.limit = n
      default:
        if arg.hasPrefix("--") { return nil }
        options.words.append(arg)
      }
    }
    return options
  }

  /// 引数が使い方に合わなければ false を返す。
  typealias Command = @Sendable (_ client: AppClient, _ options: Options) async throws -> Bool

  /// 命令の一覧。main.swift もこれで振り分ける。
  static let commands: [String: Command] = [
    "search": { client, options in
      guard !options.words.isEmpty else { return false }
      try await search(client, options.words.joined(separator: " "), options)
      return true
    },
    "similar": { client, options in
      guard options.words.count == 1, let target = options.words.first else { return false }
      let shots: [ShotView]
      if FileManager.default.fileExists(atPath: target) {
        let url = URL(fileURLWithPath: target)
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType else {
          throw ClientError("\(target) は画像のファイルではない")
        }
        shots = try await client.similar(image: try Data(contentsOf: url), mimeType: mime, sources: nil, kinds: nil, limit: options.limit)
      } else {
        shots = try await client.similar(id: target, sources: nil, kinds: nil, limit: options.limit)
      }
      try printShots(shots, json: options.json)
      return true
    },
    "selection": { client, options in
      try printShots(try await client.selection(), json: options.json)
      return true
    },
    "sync": { client, options in
      guard options.words.count <= 1 else { return false }
      try await client.sync(source: options.words.first)
      print("取得を始めた: \(options.words.first ?? "全サイト")")
      return true
    },
    "status": { client, options in
      let sources = try await client.sources()
      print(options.json ? try jsonLine(SourcesResponse(sources: sources)) : MCPServer.describe(sources))
      return true
    },
  ]

  static func run(_ name: String, _ args: [String]) async -> Int32 {
    guard let command = commands[name], let options = parse(args) else {
      fputs(usage + "\n", stderr)
      return 64
    }
    do {
      let client = try await AppClient.connect(paths: try Paths.resolveHome())
      guard try await command(client, options) else {
        fputs(usage + "\n", stderr)
        return 64
      }
      return 0
    } catch {
      fputs("Mitate \(name): \(error)\n", stderr)
      return 1
    }
  }

  private static func search(_ client: AppClient, _ query: String, _ options: Options) async throws {
    for try await event in client.search(query, sources: nil, kinds: nil, limit: options.limit, live: options.live) {
      if options.json {
        print(try jsonLine(event))
        continue
      }
      switch event {
      case let .local(shots):
        print("手元 \(shots.count) 件")
        printList(shots)
      case let .live(source, shots):
        print("\(source) から \(shots.count) 件")
        printList(shots)
      case let .error(source, message):
        print("\(source): \(message)")
      case .done:
        break
      }
    }
  }

  private static func printShots(_ shots: [ShotView], json: Bool) throws {
    if json {
      print(try jsonLine(ShotsResponse(shots: shots)))
    } else {
      print("\(shots.count) 件")
      printList(shots)
    }
  }

  private static func printList(_ shots: [ShotView]) {
    for (i, shot) in shots.enumerated() {
      print("  \(i + 1). \(shot.title.map(MCPServer.oneLine) ?? "（タイトルなし）")  [\(shot.source)・\(shot.kind.rawValue)]  \(shot.url)  \(shot.id)\(shot.note.map { "  メモ: \($0)" } ?? "")")
    }
  }

  private static func jsonLine<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}
