import CoreGraphics
import Foundation
import ImageIO
import MitateCore
import Testing

struct SigLIPEmbedderTests {
  @Test func 変種まで含めた名前と次元() throws {
    let embedder = try SigLIPFixture.embedder.get()
    let expected = try SigLIPFixture.embeddings.get()
    #expect(embedder.model == expected.model)
    #expect(embedder.dimension == expected.text[0].count)
  }

  @Test func 文章の埋め込みがPythonと一致する() throws {
    let embedder = try SigLIPFixture.embedder.get()
    let expected = try SigLIPFixture.embeddings.get()
    for (query, vector) in zip(expected.queries, expected.text) {
      let v = try embedder.embed(text: query)
      #expect(cosine(v, vector) >= 0.9999, "\(query)")
      #expect(abs(cosine(v, v) - 1) < 1e-5)
    }
  }

  @Test func 画像の埋め込みがPythonと一致する() throws {
    let embedder = try SigLIPFixture.embedder.get()
    let expected = try SigLIPFixture.embeddings.get()
    for (name, vector) in zip(expected.images, expected.image) {
      let v = try embedder.embed(image: try Self.image(name))
      #expect(cosine(v, vector) >= 0.995, "\(name)")
    }
  }

  /// Python で差が `margin` 以下の組は数値誤差で入れ替わりうるので比べない
  @Test func 検索語と画像の類似度の大小がPythonと同じになる() throws {
    let margin: Float = 0.002
    let embedder = try SigLIPFixture.embedder.get()
    let expected = try SigLIPFixture.embeddings.get()
    let texts = try expected.queries.map { try embedder.embed(text: $0) }
    let images = try expected.images.map { try embedder.embed(image: try Self.image($0)) }
    let sims = texts.map { t in images.map { cosine(t, $0) } }
    let cells = texts.indices.flatMap { q in images.indices.map { (q, $0) } }
    var compared = 0
    for (q, i) in cells {
      #expect(abs(sims[q][i] - expected.similarity[q][i]) < margin, "\(expected.queries[q]) × \(expected.images[i])")
    }
    for (a, b) in cells.flatMap({ a in cells.map { (a, $0) } }) where (a.0 == b.0) != (a.1 == b.1) {
      let py = expected.similarity[a.0][a.1] - expected.similarity[b.0][b.1]
      guard abs(py) > margin else { continue }
      compared += 1
      #expect((sims[a.0][a.1] > sims[b.0][b.1]) == (py > 0), "\(expected.queries[a.0]) × \(expected.images[a.1]) と \(expected.queries[b.0]) × \(expected.images[b.1])")
    }
    #expect(compared > 0)
  }

  @Test func ファイルが欠けていれば名前を挙げて止める() throws {
    let source = try SigLIPFixture.modelDirectory()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("onnx"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.copyItem(at: source.appendingPathComponent("config.json"), to: dir.appendingPathComponent("config.json"))
    do {
      _ = try SigLIPEmbedder(directory: dir)
      Issue.record("例外にならなかった")
    } catch let SigLIPError.missing(_, files) {
      #expect(files == ["tokenizer.json", "preprocessor_config.json", "onnx/vision_model*.onnx", "onnx/text_model*.onnx"])
    }
  }

  static func image(_ name: String) throws -> CGImage {
    let url = try SigLIPFixture.file("images/\(name)")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw FixtureError(description: "\(name) を読めない")
    }
    return image
  }
}
