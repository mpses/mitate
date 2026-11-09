export interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
  col: number;
}

export interface Layout {
  boxes: Box[];
  /** 列ごとの、上から順の index */
  columns: number[][];
  height: number;
}

export function columnCount(width: number, minColumnWidth: number, gap: number): number {
  return Math.max(1, Math.floor((width + gap) / (minColumnWidth + gap)));
}

/** 縦横比（幅 ÷ 高さ）の並びを、その時点でいちばん低い列へ順に積む */
export function layout(
  aspects: readonly number[],
  width: number,
  minColumnWidth: number,
  gap: number,
): Layout {
  const count = columnCount(width, minColumnWidth, gap);
  const w = (width - gap * (count - 1)) / count;
  const bottoms = Array.from({ length: count }, () => 0);
  const columns = Array.from({ length: count }, (): number[] => []);
  const boxes = aspects.map((aspect, i) => {
    const col = bottoms.indexOf(Math.min(...bottoms));
    const box = { x: col * (w + gap), y: bottoms[col], w, h: w / aspect, col };
    bottoms[col] += box.h + gap;
    columns[col].push(i);
    return box;
  });
  return { boxes, columns, height: Math.max(0, Math.max(...bottoms) - gap) };
}

export function visible({ boxes }: Layout, top: number, bottom: number): number[] {
  const out: number[] = [];
  boxes.forEach((box, i) => {
    if (box.y < bottom && box.y + box.h > top) out.push(i);
  });
  return out;
}

export type Direction = "left" | "right" | "up" | "down";

/** ↑↓ は同じ列の前後、←→ は隣の列で縦の中心がいちばん近いもの */
export function neighbor(
  { boxes, columns }: Layout,
  index: number,
  direction: Direction,
): number | undefined {
  const box = boxes[index];
  if (!box) return undefined;
  if (direction === "up" || direction === "down") {
    const column = columns[box.col];
    return column[column.indexOf(index) + (direction === "down" ? 1 : -1)];
  }
  const column = columns[box.col + (direction === "right" ? 1 : -1)] ?? [];
  const center = box.y + box.h / 2;
  let best: number | undefined;
  let bestDistance = Infinity;
  for (const i of column) {
    const { y, h } = boxes[i];
    const distance = Math.max(0, y - center, center - (y + h));
    if (distance < bestDistance) {
      best = i;
      bestDistance = distance;
    }
  }
  return best;
}
