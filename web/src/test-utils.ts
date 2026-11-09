/** 壁が知らせを受ける幅。4 列になる */
export const WALL_WIDTH = 960;

/**
 * 壁（ShotWall）を描くのに要る、jsdom に無い窓の機能を足す。
 * ResizeObserver は observe した時点で WALL_WIDTH を知らせ、壁の隙間の CSS 変数は style で置く
 */
export function installWallDom() {
  window.ResizeObserver = class {
    readonly #callback: ResizeObserverCallback;
    constructor(callback: ResizeObserverCallback) {
      this.#callback = callback;
    }
    observe(target: Element) {
      const entry = { target, contentRect: { width: WALL_WIDTH } } as ResizeObserverEntry;
      this.#callback([entry], this);
    }
    unobserve() {}
    disconnect() {}
  };
  Element.prototype.scrollIntoView = () => {};
  Element.prototype.scrollTo = () => {};
  Element.prototype.animate = () => ({ finished: Promise.resolve() }) as unknown as Animation;
  Object.defineProperty(document, "fonts", {
    configurable: true,
    value: { load: () => Promise.resolve([]) },
  });
  if (!document.getElementById("wall-gap")) {
    document.head.insertAdjacentHTML(
      "beforeend",
      '<style id="wall-gap">div { --wall-gap: 12px }</style>',
    );
  }
}

/**
 * jsdom に無い CSSTransition の代わり。finish と cancel で finished を決める。
 * vi.stubGlobal("CSSTransition", FakeTransition) で instanceof を通し、asAnimation() を getAnimations の戻り値に入れる
 */
export class FakeTransition {
  effect: object | null = {};
  timeline: object | null = {};
  readonly finished: Promise<unknown>;
  finish: () => void = () => {};
  cancel: () => void = () => {};

  constructor() {
    this.finished = new Promise((resolve, reject) => {
      this.finish = () => resolve(this);
      this.cancel = () => reject(new DOMException("canceled", "AbortError"));
    });
  }

  asAnimation(): Animation {
    return this as unknown as Animation;
  }
}
