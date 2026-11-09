import Foundation
@testable import MitateCore
import Testing

struct SigLIPSessionTests {
  @Test func 使うまでsessionを作らず_待ちが過ぎたら放して_次の呼び出しで作り直す() async throws {
    let embedder = try SigLIPEmbedder(directory: SigLIPFixture.modelDirectory(), executionProvider: .cpu, idleSeconds: 0.2)
    #expect(embedder.dimension == 768)
    #expect(!embedder.loaded.vision && !embedder.loaded.text)

    let text = try embedder.embed(text: "toggle switch")
    #expect(embedder.loaded.text && !embedder.loaded.vision)
    try await Self.waitUntil { !embedder.loaded.text }
    #expect(try embedder.embed(text: "toggle switch") == text)

    let image = try SigLIPEmbedderTests.image("toggle.jpg")
    let vector = try embedder.embed(image: image)
    #expect(embedder.loaded.vision)
    try await Self.waitUntil { !embedder.loaded.vision }
    #expect(try embedder.embed(image: image) == vector)
  }

  @Test func 並行して呼ぶ間に放しても落ちず_同じ値を返す() throws {
    let embedder = try SigLIPEmbedder(directory: SigLIPFixture.modelDirectory(), executionProvider: .cpu, idleSeconds: 0.01)
    let image = try SigLIPEmbedderTests.image("dash.jpg")
    let text = try embedder.embed(text: "dashboard with charts")
    let vector = try embedder.embed(image: image)
    let lock = NSLock()
    var results: [(Int, Result<[Float], Error>)] = []
    DispatchQueue.concurrentPerform(iterations: 6) { worker in
      for k in 0 ..< 4 {
        // 待ちを過ぎる間を挟み、放すのと次の呼び出しを入り混じらせる
        Thread.sleep(forTimeInterval: Double((worker + k) % 3) * 0.15)
        let i = worker * 4 + k
        let result = Result { i % 2 == 0 ? try embedder.embed(text: "dashboard with charts") : try embedder.embed(image: image) }
        lock.withLock { results.append((i, result)) }
      }
    }
    #expect(results.count == 24)
    for (i, result) in results {
      #expect(try result.get() == (i % 2 == 0 ? text : vector), "\(i)")
    }
  }

  @Test func 途中で切れたモデルのファイルは読み込みで止める() throws {
    let source = try SigLIPFixture.modelDirectory()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let onnx = dir.appendingPathComponent("onnx")
    try FileManager.default.createDirectory(at: onnx, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["config.json", "tokenizer.json", "preprocessor_config.json"] {
      try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: source.appendingPathComponent(name))
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: source.appendingPathComponent("onnx").path)
    let vision = try #require(names.first { $0.hasPrefix("vision_model") && $0.hasSuffix(".onnx") })
    let text = try #require(names.first { $0.hasPrefix("text_model") && $0.hasSuffix(".onnx") })
    try FileManager.default.createSymbolicLink(at: onnx.appendingPathComponent(text), withDestinationURL: source.appendingPathComponent("onnx/\(text)"))
    let original = source.appendingPathComponent("onnx/\(vision)")
    let size = try #require(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let head = try FileHandle(forReadingFrom: original)
    defer { try? head.close() }
    try #require(try head.read(upToCount: min(size / 2, 4 << 20))).write(to: onnx.appendingPathComponent(vision))

    do {
      _ = try SigLIPEmbedder(directory: dir)
      Issue.record("例外にならなかった")
    } catch let SigLIPError.model(file, _) {
      #expect(file.hasSuffix(vision))
    }
  }

  private static func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 100 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    Issue.record("5 秒待っても条件を満たさない")
  }
}
