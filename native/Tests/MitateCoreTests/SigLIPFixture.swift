import Foundation
import MitateCore

struct FixtureError: Error, CustomStringConvertible {
  let description: String
}

/// 期待値は `make_fixtures.py` が Python の AutoTokenizer と ONNX Runtime で作る
enum SigLIPFixture {
  /// モデルは大きいのでリポジトリに置かず、`MITATE_SIGLIP_DIR` で場所を受け取る
  static func modelDirectory() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["MITATE_SIGLIP_DIR"], !path.isEmpty else {
      throw FixtureError(description: "MITATE_SIGLIP_DIR に SigLIP 2 のモデルのディレクトリ（models.mjs の置き先）を指定する")
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func file(_ name: String) throws -> URL {
    guard let root = Bundle.module.resourceURL else { throw FixtureError(description: "テストのリソースが無い") }
    let url = root.appendingPathComponent("Fixtures").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { throw FixtureError(description: "\(url.path) が無い") }
    return url
  }

  static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: file(name)))
  }

  static let tokenizer = Result { try GemmaTokenizer(file: modelDirectory().appendingPathComponent("tokenizer.json")) }
  static let embedder = Result { try SigLIPEmbedder(directory: modelDirectory()) }
  static let embeddings = Result { try decode(Embeddings.self, "embeddings.json") }

  struct TokenizerCase: Decodable {
    let text: String
    let ids: [Int32]
    let lower: String
    let lowerIds: [Int32]
    let untruncatedLength: Int
  }

  struct Embeddings: Decodable {
    let model: String
    let queries: [String]
    let text: [[Float]]
    let images: [String]
    let image: [[Float]]
    let similarity: [[Float]]
  }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
  var dot: Float = 0
  var na: Float = 0
  var nb: Float = 0
  for i in a.indices {
    dot += a[i] * b[i]
    na += a[i] * a[i]
    nb += b[i] * b[i]
  }
  return dot / (na.squareRoot() * nb.squareRoot())
}
