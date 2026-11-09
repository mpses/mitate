// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

import { playVideo } from "./video";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("playVideo", () => {
  it("pause() や load() で打ち切られた再生は reject にしない", async () => {
    vi.spyOn(HTMLMediaElement.prototype, "play").mockRejectedValue(
      new DOMException("The operation was aborted.", "AbortError"),
    );
    await expect(playVideo(document.createElement("video"))).resolves.toBeUndefined();
  });

  it("打ち切り以外の失敗は reject のまま返す", async () => {
    const refused = new DOMException("The request is not allowed.", "NotAllowedError");
    vi.spyOn(HTMLMediaElement.prototype, "play").mockRejectedValue(refused);
    await expect(playVideo(document.createElement("video"))).rejects.toBe(refused);
  });
});
