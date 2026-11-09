import Foundation

public enum SimilarTarget: Sendable {
  case shot(String)
  case image(Data)
}

/// HTTP の殻（Server）と MCP が使う、索引の操作の全部。実装は `Engine`。
public protocol EngineAPI: AnyObject, Sendable {
  func sources() async -> [SourceStatus]
  /// 検索語が無いときの壁。新しいものから、サイトが続かないように並べる
  func browse(sources: Set<String>?, offset: Int, limit: Int) async throws -> [ShotView]
  /// 手元の結果を `.local` で 1 回流し、`live` が真ならサイトへ問い合わせた結果を `.live` で届いた順に流し、最後に `.done` を流す。
  /// `kinds` が nil なら全種類
  func search(_ query: String, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int, live: Bool) -> AsyncThrowingStream<SearchEvent, Error>
  func similar(to target: SimilarTarget, sources: Set<String>?, kinds: Set<ShotKind>?, limit: Int) async throws -> [ShotView]
  func shot(_ id: String) async throws -> ShotView
  func selection() async throws -> [ShotView]
  func setSelection(_ id: String, _ update: SelectionUpdate) async throws -> ShotView
  func clearSelection() async throws
  /// 差分の取得を始める。`source` が nil なら全サイト。終わりを待たずに返る
  func sync(source: String?) async
  /// ログイン画面を閉じたあとに呼ぶ。ログイン状態を確かめ直し、ログインできていれば取得を始める
  func signInChanged(source: String) async
  /// 番号付きのコンタクトシート（JPEG）。番号は ids の順で 1 から
  func sheet(ids: [String]) async throws -> Data
  /// 動画を等間隔に count 枚並べた JPEG と、各フレームの時刻（ms）
  func frames(id: String, count: Int) async throws -> (jpeg: Data, times: [Int])
  /// 長辺 1568px までの元画像（JPEG）
  func view(id: String) async throws -> Data
  /// `/media/<key>` に当たる手元のファイル
  func mediaFile(key: String) -> URL?
  func source(_ id: String) -> SourceFile?
}
