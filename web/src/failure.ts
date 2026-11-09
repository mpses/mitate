import { useSyncExternalStore } from "react";

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, { postMessage(message: unknown): void } | undefined>;
    };
  }
}

/** アプリの窓で失敗を受け取る WKScriptMessageHandler の名前。送る形は FailureMessage */
export const NATIVE_FAILURE_HANDLER = "mitateFailure";

export interface FailureMessage {
  kind: "error" | "unhandledrejection";
  message: string;
  stack?: string;
}

let failed = false;
const listeners = new Set<() => void>();

function setFailed(value: boolean) {
  if (failed === value) return;
  failed = value;
  for (const listener of listeners) listener();
}

function report(kind: FailureMessage["kind"], reason: unknown) {
  const error = reason instanceof Error ? reason : new Error(String(reason));
  const message: FailureMessage = { kind, message: error.message, stack: error.stack };
  // dev のブラウザには handler が無い。そこでは console に出る既定の表示だけになる
  window.webkit?.messageHandlers?.[NATIVE_FAILURE_HANDLER]?.postMessage(message);
  setFailed(true);
}

/** 拾われなかった例外と reject を受け、検索欄の印と native のログへ回す。既定の console 出力は止めない */
export function installFailureReporting() {
  window.addEventListener("error", (event) => report("error", event.error ?? event.message));
  window.addEventListener("unhandledrejection", (event) =>
    report("unhandledrejection", event.reason),
  );
}

/** 新しい問いを引き直すときに、前の失敗の印を消す */
export const clearFailure = () => setFailed(false);

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

export function useFailed(): boolean {
  return useSyncExternalStore(subscribe, () => failed);
}
