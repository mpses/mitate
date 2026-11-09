import { describe, expect, it } from "vitest";

import { columnCount, layout, neighbor, visible } from "./masonry";

// 幅 320・最小列幅 100・間隔 10 で 3 列、列幅 100
//   列 0: #0 (0–100)  #3 (110–210)
//   列 1: #1 (0–200)
//   列 2: #2 (0–100)  #4 (110–160)
const grid = layout([1, 0.5, 1, 1, 2], 320, 100, 10);

describe("layout", () => {
  it("窓の幅と最小列幅から列数を決める", () => {
    expect(columnCount(320, 100, 10)).toBe(3);
    expect(columnCount(80, 100, 10)).toBe(1);
  });

  it("縦横比を保ち、いちばん低い列へ積む", () => {
    expect(grid.columns).toEqual([[0, 3], [1], [2, 4]]);
    expect(grid.boxes[1]).toEqual({ x: 110, y: 0, w: 100, h: 200, col: 1 });
    expect(grid.boxes[4]).toEqual({ x: 220, y: 110, w: 100, h: 50, col: 2 });
    expect(grid.height).toBe(210);
  });

  it("空の壁の高さは 0", () => {
    expect(layout([], 320, 100, 10).height).toBe(0);
  });

  it("表示範囲に掛かるものだけを返す", () => {
    expect(visible(grid, 150, 300)).toEqual([1, 3, 4]);
  });
});

describe("neighbor", () => {
  it("↑↓ は同じ列の前後", () => {
    expect(neighbor(grid, 0, "down")).toBe(3);
    expect(neighbor(grid, 3, "up")).toBe(0);
    expect(neighbor(grid, 3, "down")).toBeUndefined();
  });

  it("←→ は隣の列で縦の中心が近いもの", () => {
    expect(neighbor(grid, 3, "right")).toBe(1);
    expect(neighbor(grid, 1, "right")).toBe(2);
    expect(neighbor(grid, 4, "left")).toBe(1);
    expect(neighbor(grid, 0, "left")).toBeUndefined();
    expect(neighbor(grid, 2, "right")).toBeUndefined();
  });
});
