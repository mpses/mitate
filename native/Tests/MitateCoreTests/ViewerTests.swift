import Foundation
import JavaScriptCore
import Testing
@testable import MitateCore

struct ViewerTests {
  let viewer = URL(string: "http://127.0.0.1:5123/")!

  @Test func onlyTheViewerOriginStaysInTheWindow() {
    #expect(ViewerPolicy.decide(URL(string: "http://127.0.0.1:5123/assets/a.js")!, isMainFrame: true, viewer: viewer) == .allow)
    #expect(ViewerPolicy.decide(URL(string: "https://designspells.com/spells/x")!, isMainFrame: true, viewer: viewer) == .openOutside)
    #expect(ViewerPolicy.decide(URL(string: "http://localhost:5123/")!, isMainFrame: true, viewer: viewer) == .openOutside)
    #expect(ViewerPolicy.decide(URL(string: "http://127.0.0.1:9999/")!, isMainFrame: true, viewer: viewer) == .openOutside)
    #expect(ViewerPolicy.decide(URL(string: "https://x.com/i/status/1")!, isMainFrame: nil, viewer: viewer) == .openOutside)
    #expect(ViewerPolicy.decide(URL(string: "file:///Users/me/a.png")!, isMainFrame: true, viewer: viewer) == .block)
    #expect(ViewerPolicy.decide(URL(string: "https://www.youtube.com/embed/x")!, isMainFrame: false, viewer: viewer) == .allow)
  }

  private func evaluate(origin: String) throws -> JSValue {
    let ctx = try #require(JSContext())
    ctx.evaluateScript("var window = {}; var location = { origin: \(ViewerPolicy.jsString(origin)) };")
    ctx.evaluateScript(ViewerPolicy.tokenScript(viewer: viewer, token: "t\"o'k"))
    return try #require(ctx.evaluateScript("window.__MITATE__ ? window.__MITATE__.token : null"))
  }

  @Test func tokenGoesOnlyToTheViewerOrigin() throws {
    #expect(try evaluate(origin: "http://127.0.0.1:5123").toString() == "t\"o'k")
    #expect(try evaluate(origin: "https://evil.example").isNull)
    #expect(try evaluate(origin: "http://localhost:5123").isNull)
  }

  @Test func failureReportsBecomeOneLogLine() {
    #expect(ViewerPolicy.failureLine(["kind": "error", "message": "x is undefined", "stack": "at App"]) == "viewer: error x is undefined\nat App")
    #expect(ViewerPolicy.failureLine(["kind": "unhandledrejection", "message": "HTTP 500"]) == "viewer: unhandledrejection HTTP 500")
    #expect(ViewerPolicy.failureLine("text").hasPrefix("viewer: 形の違う失敗の報告"))
  }

  @Test func dragMessagesCarryShotIds() {
    #expect(ViewerPolicy.dragIds(["ids": ["detail:1", "x:2"]]) == ["detail:1", "x:2"])
    #expect(ViewerPolicy.dragIds(["ids": [String]()]) == [])
    #expect(ViewerPolicy.dragIds(["ids": [1]]) == nil)
    #expect(ViewerPolicy.dragIds("detail:1") == nil)
  }

  @Test func faviconLinksIgnoreAMislabeledType() {
    let base = URL(string: "https://bestdesignsonx.com/")!
    let html = """
      <link rel="icon" type="image/svg+xml" href="/favicon.webp" />
      <link href="/favicon.svg" rel="icon" type="image/svg+xml"/>
      <link rel="apple-touch-icon" sizes="180x180" href="/apple.png">
      """
    #expect(Thumbnailer.iconLinks(in: html, base: base).map(\.absoluteString) == ["https://bestdesignsonx.com/apple.png", "https://bestdesignsonx.com/favicon.webp"])
  }
}
