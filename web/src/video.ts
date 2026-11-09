import { useCallback, type RefCallback } from "react";

/**
 * 再生を止め、復号器とフレームの資源を放す。
 * WebKit は <video> を DOM から外しても、src を外して load() を呼ぶまで GPU プロセスの資源を持ち続けることがある
 */
export function releaseVideo(video: HTMLVideoElement) {
  video.pause();
  video.removeAttribute("src");
  video.load();
}

/**
 * 再生を始める。最初のフレームを待つ間に pause() や releaseVideo で打ち切ると、play() は AbortError で reject する。
 * それはこちらが止めた結果なので捨て、ほかの失敗は reject のまま返す
 */
export function playVideo(video: HTMLVideoElement): Promise<void> {
  return video.play().catch((error: unknown) => {
    if (!(error instanceof DOMException && error.name === "AbortError")) throw error;
  });
}

/** <video> に src を付け、要素が外れるときに資源を放す ref */
export function useVideoSource(src: string): RefCallback<HTMLVideoElement> {
  return useCallback(
    (video: HTMLVideoElement) => {
      video.src = src;
      return () => releaseVideo(video);
    },
    [src],
  );
}

/** ホバーで動画を再生しているタイル。焦点表示の中の壁も含め、同時に 1 つまで */
let hovering: { tile: Element; stop: () => void } | undefined;

/** tile でホバー再生を始める。ほかのタイルが再生していれば、その stop を呼んで止める */
export function claimHoverPlayback(tile: Element, stop: () => void) {
  if (hovering && hovering.stop !== stop) hovering.stop();
  hovering = { tile, stop };
}

/** stop を渡したタイルが再生をやめた */
export function endHoverPlayback(stop: () => void) {
  if (hovering?.stop === stop) hovering = undefined;
}

/** root の中のタイルがホバー再生していれば止める。壁を差し替えたときに呼ぶ */
export function stopHoverPlaybackIn(root: Element) {
  if (!hovering || !root.contains(hovering.tile)) return;
  const { stop } = hovering;
  hovering = undefined;
  stop();
}
