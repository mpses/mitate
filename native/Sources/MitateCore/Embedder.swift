import CoreGraphics
import Foundation

public protocol Embedder: Sendable {
  /// vectors.model に保存する名前。変わったら全件を計算し直す
  var model: String { get }
  var dimension: Int { get }
  func embed(image: CGImage) throws -> [Float]
  func embed(text: String) throws -> [Float]
}

public enum EmbedderError: Error, CustomStringConvertible {
  case notConfigured
  case failed(String)

  public var description: String {
    switch self {
    case .notConfigured: "埋め込みモデル未設定"
    case let .failed(m): "埋め込みに失敗: \(m)"
    }
  }
}
