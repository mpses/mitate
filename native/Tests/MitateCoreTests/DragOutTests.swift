import Foundation
import Testing
@testable import MitateCore

struct DragOutTests {
  private func view(_ id: String, kind: ShotKind = .image, thumb: String? = "/media/a.jpg", title: String? = nil, text: String? = nil, origin: String? = nil) -> ShotView {
    let source = String(id.prefix { $0 != ":" })
    return ShotView(id: id, source: source, url: "https://example.com/\(source)", origin: origin, kind: kind, title: title, text: text, tags: [], author: nil, publishedAt: nil, thumb: thumb, media: nil, aspect: nil, colors: [], duplicates: 1, selected: false, note: nil)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mitate-dragout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func fileNamesMapBackToTheShotId() throws {
    let out = DragOut(root: URL(fileURLWithPath: "/drag", isDirectory: true))
    #expect(try out.file(for: view("detail:abc-123")).path == "/drag/detail/abc-123.jpg")
    #expect(try out.file(for: view("designengineer-tools:a/b c", kind: .text)).path == "/drag/designengineer-tools/a%2Fb%20c.md")
    #expect(try out.file(for: view("x:.hidden")).lastPathComponent == "%2Ehidden.jpg")
    let long = try out.file(for: view("x:" + String(repeating: "a", count: 300)))
    #expect(long.deletingPathExtension().lastPathComponent == Thumbnailer.key(for: "x:" + String(repeating: "a", count: 300)))
    #expect(throws: DragOutError.self) { try out.file(for: ShotView(id: "other:1", source: "x", url: "https://example.com", origin: nil, kind: .image, title: nil, text: nil, tags: [], author: nil, publishedAt: nil, thumb: nil, media: nil, aspect: nil, colors: [], duplicates: 1, selected: false, note: nil)) }
  }

  @Test func textBecomesMarkdownWithItsSource() {
    let shot = view("recent:1", kind: .text, thumb: nil, title: "Spacing", text: "Use 8px steps.", origin: "https://x.com/i/status/1")
    #expect(DragOut.markdown(shot) == "# Spacing\n\nhttps://example.com/recent\n\nhttps://x.com/i/status/1\n\nUse 8px steps.\n")
  }

  @Test func writesThumbnailsAndSkipsShotsWithoutOne() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let thumb = root.appendingPathComponent("thumb.jpg")
    try Data([0xFF, 0xD8, 0xFF]).write(to: thumb)
    let out = DragOut(root: root.appendingPathComponent("drag", isDirectory: true))
    let shots = [view("detail:1"), view("detail:2", thumb: nil), view("recent:3", kind: .text, thumb: nil, text: "body")]
    // 同じ Shot を 2 度渡しても、前のファイルを置き換えて書ける
    _ = try out.write(shots, thumb: { $0 == "/media/a.jpg" ? thumb : nil })
    let written = try out.write(shots, thumb: { $0 == "/media/a.jpg" ? thumb : nil })
    #expect(written.files.map(\.view.id) == ["detail:1", "recent:3"])
    #expect(written.missing == ["detail:2"])
    #expect(try Data(contentsOf: written.files[0].file) == Data([0xFF, 0xD8, 0xFF]))
    #expect(try String(contentsOf: written.files[1].file, encoding: .utf8).hasSuffix("body\n"))
  }
}
