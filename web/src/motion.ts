import { useSyncExternalStore } from "react";

import { token } from "@bakutan-org/ui/styled-system/tokens";

/** WAAPI に渡す token の motion。duration は ms の数に直す */
export const motion = {
  fast: Number.parseFloat(token("durations.fast")),
  normal: Number.parseFloat(token("durations.normal")),
  out: token("easings.out"),
};

/**
 * 動きが終わるか取り消されたら、効果と timeline から外す。
 * WebKit は script から触った動きを、終わった後も timeline にある間は放さず、効果が指す要素を DOM から外した後も持ち続ける。
 * 効果を外すと要素が、timeline を外すと動きそのものが放れる
 */
function releaseWhenDone(animation: Animation) {
  const release = () => {
    animation.effect = null;
    animation.timeline = null;
  };
  animation.finished.then(release, release);
}

/** WAAPI の動きを一度だけ流し、終わったら放す */
export function animateOnce(
  element: Element,
  keyframes: Keyframe[],
  options: KeyframeAnimationOptions,
): Animation {
  const animation = element.animate(keyframes, options);
  releaseWhenDone(animation);
  return animation;
}

/**
 * 要素自身の CSS transition を、終わったら放す。その要素の onTransitionRun に渡す。
 * Base UI は Popup の開閉の終わりを getAnimations() で待つので、Popup の transition は script から触られ、閉じた Popup が中身ごと残る
 */
export function releaseOwnTransitions(event: { currentTarget: Element; target: EventTarget }) {
  if (event.target !== event.currentTarget) return;
  for (const animation of event.currentTarget.getAnimations()) {
    if (animation instanceof CSSTransition) releaseWhenDone(animation);
  }
}

/** aspect が分からないタイルと、文字のタイルの縦横比 */
export const fallbackAspect = (() => {
  const [w, h] = token("aspectRatios.landscape").split("/").map(Number.parseFloat);
  return w / h;
})();

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

const subscribe = (onChange: () => void) => {
  reducedMotion.addEventListener("change", onChange);
  return () => reducedMotion.removeEventListener("change", onChange);
};

export function useReducedMotion(): boolean {
  return useSyncExternalStore(subscribe, () => reducedMotion.matches);
}
