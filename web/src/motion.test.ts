// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

import { animateOnce, releaseOwnTransitions } from "./motion";
import { FakeTransition } from "./test-utils";

// motion.ts は読み込んだ時点で matchMedia を引くので、import より先に置く
vi.hoisted(() => {
  window.matchMedia = (media: string) =>
    ({
      matches: false,
      media,
      addEventListener: () => {},
      removeEventListener: () => {},
    }) as unknown as MediaQueryList;
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function animateWith(finished: Promise<Animation>) {
  const element = document.createElement("div");
  const animation = { finished, effect: {}, timeline: {} } as unknown as Animation;
  element.animate = () => animation;
  return animateOnce(element, [{ opacity: 0 }, { opacity: 1 }], { duration: 10 });
}

/** then の後に走る release を待つ */
const settled = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("animateOnce", () => {
  it("終わった動きを効果と timeline から外し、対象の要素と動きを放す", async () => {
    const animation = animateWith(Promise.resolve({} as Animation));
    expect(animation.effect).not.toBeNull();
    await settled();
    expect(animation.effect).toBeNull();
    expect(animation.timeline).toBeNull();
  });

  it("取り消された動きも放す", async () => {
    const animation = animateWith(Promise.reject(new DOMException("canceled", "AbortError")));
    await settled();
    expect(animation.effect).toBeNull();
    expect(animation.timeline).toBeNull();
  });
});

describe("releaseOwnTransitions", () => {
  it("要素自身の CSS transition を、終わったら放す", async () => {
    vi.stubGlobal("CSSTransition", FakeTransition);
    const element = document.createElement("div");
    const transition = new FakeTransition();
    const animation = { finished: Promise.resolve(), effect: {}, timeline: {} };
    element.getAnimations = () => [transition.asAnimation(), animation as unknown as Animation];

    releaseOwnTransitions({ currentTarget: element, target: element });
    await settled();
    expect(transition.effect).not.toBeNull();

    transition.finish();
    await settled();
    expect(transition.effect).toBeNull();
    expect(transition.timeline).toBeNull();
    // transition ではない動きは、それを流した側が放す
    expect(animation.timeline).not.toBeNull();
  });

  it("取り消された transition も放す", async () => {
    vi.stubGlobal("CSSTransition", FakeTransition);
    const element = document.createElement("div");
    const transition = new FakeTransition();
    element.getAnimations = () => [transition.asAnimation()];

    releaseOwnTransitions({ currentTarget: element, target: element });
    transition.cancel();
    await settled();
    expect(transition.timeline).toBeNull();
  });

  it("子から伝わってきた transitionrun では何もしない", () => {
    vi.stubGlobal("CSSTransition", FakeTransition);
    const element = document.createElement("div");
    const child = document.createElement("span");
    element.append(child);
    const getAnimations = vi.fn(() => []);
    element.getAnimations = getAnimations;

    releaseOwnTransitions({ currentTarget: element, target: child });
    expect(getAnimations).not.toHaveBeenCalled();
  });
});
