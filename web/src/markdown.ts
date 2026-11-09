import type { ShotView } from "./api";

const escapeText = (text: string) => text.replace(/[[\]\\]/g, (c) => `\\${c}`);

// 括弧や空白を含む URL は <> で囲まないとリンクの終わりを取り違える
const link = (url: string) => (/[\s()<>]/.test(url) ? `<${url}>` : url);

/** 選んだ Shot を、AI に参考として渡せる Markdown の箇条書きにする */
export function selectionMarkdown(shots: readonly ShotView[]): string {
  return shots
    .map((shot) => {
      const lines = [`- [${escapeText(shot.title ?? shot.url)}](${link(shot.url)})`];
      if (shot.origin) lines.push(`  - origin: ${shot.origin}`);
      if (shot.note) lines.push(`  - メモ: ${shot.note}`);
      return lines.join("\n");
    })
    .join("\n");
}
