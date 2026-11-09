import { useCallback, useLayoutEffect, useRef } from "react";

/** 毎回同じ関数を返し、呼ばれたときは最新の fn を実行する。memo した子へ渡す handler を描き直しの理由にしない */
export function useStableCallback<A extends unknown[], R>(
  fn: (...args: A) => R,
): (...args: A) => R {
  const latest = useRef(fn);
  useLayoutEffect(() => {
    latest.current = fn;
  });
  return useCallback((...args: A) => latest.current(...args), []);
}
