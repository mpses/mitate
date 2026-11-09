import type { ShotView } from "./api";

/** 画像で引くときの種。壁の Shot か、貼り付けやドロップで受けた画像 */
export type Seed =
  | { type: "shot"; shot: ShotView }
  | { type: "image"; image: Blob; preview: string };

/** 検索欄が持つ問い。語か種のどちらか。両方とも無ければ一覧 */
export interface Query {
  text: string;
  seed?: Seed;
}

export interface History {
  entries: readonly Query[];
  index: number;
  /** 打ち込み中の項目。続けて打つと同じ項目を書き換え、確定（commit）すると次の入力は新しい項目になる */
  draft: boolean;
}

export const initialHistory: History = { entries: [{ text: "" }], index: 0, draft: false };

/** 戻れる問いの数。種の画像（Blob）も履歴が持つので、超えたら古いものから捨てる */
export const HISTORY_LIMIT = 50;

export const current = (history: History): Query => history.entries[history.index];

export function push(history: History, query: Query): History {
  const entries = [...history.entries.slice(0, history.index + 1), query].slice(-HISTORY_LIMIT);
  return { entries, index: entries.length - 1, draft: false };
}

/** 打った語を問いにする。種は語で置き換わる */
export function edit(history: History, text: string): History {
  const now = current(history);
  if (now.text === text && !now.seed) return history;
  if (!history.draft) return { ...push(history, { text }), draft: true };
  const previous = history.entries[history.index - 1];
  // 打ち直して 1 つ前と同じ語に戻ったら、打ち込み中の項目ごと消す
  if (previous && previous.text === text && !previous.seed) {
    return {
      entries: history.entries.slice(0, history.index),
      index: history.index - 1,
      draft: false,
    };
  }
  const entries = history.entries.with(history.index, { text });
  return { ...history, entries };
}

export const commit = (history: History): History =>
  history.draft ? { ...history, draft: false } : history;

export const back = (history: History): History =>
  history.index > 0 ? { ...history, index: history.index - 1, draft: false } : history;

export const forward = (history: History): History =>
  history.index < history.entries.length - 1
    ? { ...history, index: history.index + 1, draft: false }
    : history;
