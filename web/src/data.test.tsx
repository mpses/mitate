// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { useEffect } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { parseShots, type ShotView } from "./api";
import { useWall } from "./data";
import browseFixture from "./fixtures/browse.json";
import type { Query } from "./history";

const fixture = parseShots(browseFixture);

/** 手元の Shot。同期で増える様子を、テストの途中で中身を足して表す */
const store: ShotView[] = [];
const calls: number[] = [];

vi.mock("./api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./api")>()),
  browse: async (offset: number, limit: number) => {
    calls.push(offset);
    return store.slice(offset, offset + limit);
  },
}));

/** fixture の Shot を id だけ変えて n 件にする */
function fill(n: number) {
  store.length = 0;
  for (let i = 0; i < n; i++) {
    store.push({ ...fixture[i % fixture.length], id: `test:${i}` });
  }
}

const browsing: Query = { text: "" };

/** ShotWall と同じく、子の effect から続きを求める。窓が埋まらないほど大きい壁を表す */
function Hungry({ count, onNearEnd }: { count: number; onNearEnd: () => void }) {
  useEffect(() => {
    if (count > 0) onNearEnd();
  }, [count, onNearEnd]);
  return <output>{count}</output>;
}

function Harness({ stock }: { stock: number }) {
  const { wall, loadMore } = useWall({
    query: browsing,
    scope: undefined,
    live: undefined,
    stock,
    searchable: () => [],
    beforeReplace: () => {},
  });
  return <Hungry count={wall.shots.length} onNearEnd={loadMore} />;
}

afterEach(() => {
  cleanup();
  calls.length = 0;
});

describe("useWall の browse", () => {
  it("子の effect から続きを求めると、読み終えた件数の続きから最後まで読む", async () => {
    fill(200);
    render(<Harness stock={200} />);
    await waitFor(() => expect(screen.getByRole("status").textContent).toBe("200"));
    expect(calls).toEqual([0, 80, 160]);
  });

  it("読み終えた壁が 1 ページに満たず、手元の件数が増えたら引き直す", async () => {
    fill(0);
    const { rerender } = render(<Harness stock={0} />);
    await waitFor(() => expect(calls).toEqual([0]));
    fill(5);
    rerender(<Harness stock={5} />);
    await waitFor(() => expect(screen.getByRole("status").textContent).toBe("5"));
    expect(calls).toEqual([0, 0]);
  });
});
