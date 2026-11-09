import Foundation
@testable import MitateCore
import Testing

struct GemmaTokenizerTests {
  @Test func Pythonと同じid列になる() throws {
    let tokenizer = try SigLIPFixture.tokenizer.get()
    let cases = try SigLIPFixture.decode([SigLIPFixture.TokenizerCase].self, "tokenizer_cases.json")
    #expect(cases.count >= 40)
    #expect(cases.contains { $0.untruncatedLength > tokenizer.maxLength })
    for c in cases {
      #expect(tokenizer.encode(c.text) == c.ids, "\(c.text.debugDescription)")
    }
  }

  @Test func 小文字化とその後のid列もPythonと同じになる() throws {
    let tokenizer = try SigLIPFixture.tokenizer.get()
    for c in try SigLIPFixture.decode([SigLIPFixture.TokenizerCase].self, "tokenizer_cases.json") {
      let lower = SigLIPEmbedder.lowercased(c.text)
      #expect(Array(lower.unicodeScalars) == Array(c.lower.unicodeScalars), "\(c.text.debugDescription)")
      #expect(tokenizer.encode(lower) == c.lowerIds, "\(c.text.debugDescription)")
    }
  }

  @Test func 長い文は末尾のeosを残して切り詰める() throws {
    let tokenizer = try SigLIPFixture.tokenizer.get()
    let ids = tokenizer.encode(String(repeating: "toggle switch ", count: 100))
    #expect(ids.count == tokenizer.maxLength)
    #expect(ids.last == 1)
    #expect(!ids.contains(tokenizer.padId))
  }

  @Test func 未対応の設定は読み込みで止める() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("tokenizer.json")
    try #"{"padding": null, "model": {"type": "BPE", "vocab": {}, "merges": []}}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: TokenizerError.self) { try GemmaTokenizer(file: file) }
  }
}
