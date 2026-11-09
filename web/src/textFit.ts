import type { ShotView } from "./api";

/** 文字のタイルの寸法。列幅のタイルを 1 行のタイトルと 1 行の本文で描いた見本から測る */
export interface TextMetrics {
  /** 本文の行の幅 */
  width: number;
  title: TextStyle;
  body: TextStyle;
  /** タイトルと本文の行を除いた高さ（余白、行間、サイトのアイコン） */
  chrome: number;
}

interface TextStyle {
  font: string;
  letterSpacing: string;
  line: number;
}

export interface TextLines {
  /** 0 はタイトルが無い */
  title: 0 | 1 | 2;
  body: 1 | 2 | 3 | 4;
}

const titleLines = [1, 2] as const;
const bodyLines = [1, 2, 3, 4] as const;

let context: CanvasRenderingContext2D | undefined;

function measure(text: string, style: TextStyle): number {
  context ??= document.createElement("canvas").getContext("2d") ?? undefined;
  if (!context) throw new Error("canvas の 2d context を得られない");
  context.font = style.font;
  context.letterSpacing = style.letterSpacing;
  return context.measureText(text).width;
}

/** 空白で折り返す前提で、何行になるかを数える。行幅より長い語（和文や URL）は行幅で折る（overflow-wrap: anywhere と同じ） */
function lineCount<const T extends readonly number[]>(
  text: string,
  style: TextStyle,
  width: number,
  choices: T,
): T[number] {
  const max = choices.length;
  let lines = 1;
  let line = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    // 字間と詰めは語ごとに測ると和が合わないので、行に足した形のまま測る
    if (line && measure(`${line} ${word}`, style) <= width) {
      line = `${line} ${word}`;
      continue;
    }
    if (line) lines += 1;
    const wrapped = Math.max(1, Math.ceil(measure(word, style) / width));
    lines += wrapped - 1;
    line = wrapped > 1 ? "" : word;
    if (lines >= max) break;
  }
  return choices[Math.min(max, lines) - 1];
}

export interface TextFit {
  lines: TextLines;
  height: number;
}

/**
 * 測り終えた Shot。壁は続きを足すたびに全 Shot を測り直すので、同じ寸法の間は Shot ごとに覚えておく。
 * 寸法を測り直すと別のキーになり、壁から外れた Shot は GC と一緒に消える
 */
const fitted = new WeakMap<TextMetrics, WeakMap<ShotView, TextFit>>();

export function fitText(shot: ShotView, metrics: TextMetrics): TextFit {
  let known = fitted.get(metrics);
  if (!known) {
    known = new WeakMap();
    fitted.set(metrics, known);
  }
  const cached = known.get(shot);
  if (cached) return cached;
  const lines: TextLines = {
    title: shot.title ? lineCount(shot.title, metrics.title, metrics.width, titleLines) : 0,
    body: lineCount(shot.text ?? "", metrics.body, metrics.width, bodyLines),
  };
  const height = metrics.chrome + lines.title * metrics.title.line + lines.body * metrics.body.line;
  const fit = { lines, height };
  known.set(shot, fit);
  return fit;
}

/** 見本のタイルから寸法を読む。見本には data-part="title" と "body" の 1 行ずつを入れておく */
export function readMetrics(sample: HTMLElement): TextMetrics {
  const part = (name: string) => {
    const element = sample.querySelector<HTMLElement>(`[data-part="${name}"]`);
    if (!element) throw new Error(`文字のタイルの見本に ${name} が無い`);
    const style = getComputedStyle(element);
    return {
      element,
      style: { font: style.font, letterSpacing: style.letterSpacing, line: element.offsetHeight },
    };
  };
  const title = part("title");
  const body = part("body");
  return {
    // clientWidth は整数に丸めるので、端数で折り返しが変わる行を取り違える
    width: body.element.getBoundingClientRect().width,
    title: title.style,
    body: body.style,
    chrome: sample.offsetHeight - title.style.line - body.style.line,
  };
}
