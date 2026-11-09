import { describe, expect, it } from "vitest";

import { parseSearchEvent, parseShot, parseShots, parseSources, readSearchEvents } from "./api";
import browse from "./fixtures/browse.json";
import searchNdjson from "./fixtures/search.ndjson?raw";
import selection from "./fixtures/selection.json";
import sources from "./fixtures/sources.json";

// JSON.stringify は undefined の値を落とす。parser が拾い損ねた項目があれば元の JSON と食い違う
const roundTrip = (value: unknown) => JSON.parse(JSON.stringify(value)) as unknown;

const searchLines = searchNdjson.split("\n").filter((line) => line.trim() !== "");

describe("fixture を api.ts の parser に通す", () => {
  it("browse.json と selection.json の Shot を欠かさず読む", () => {
    expect(roundTrip({ shots: parseShots(browse) })).toEqual(browse);
    expect(roundTrip({ shots: parseShots(selection) })).toEqual(selection);
  });

  it("sources.json のサイトを欠かさず読む", () => {
    expect(roundTrip({ sources: parseSources(sources) })).toEqual(sources);
  });

  it("search.ndjson の各行を欠かさず読み、最後は done で終わる", () => {
    const events = searchLines.map((line) => parseSearchEvent(JSON.parse(line)));
    expect(events.map(roundTrip)).toEqual(searchLines.map((line) => JSON.parse(line)));
    expect(events[0]?.type).toBe("local");
    expect(events.at(-1)?.type).toBe("done");
  });
});

describe("形が違う応答は例外にする", () => {
  const shot = browse.shots[0];

  it("必須の値が無い", () => {
    const { id: _id, ...rest } = shot;
    expect(() => parseShot(rest)).toThrow(/shot\.id/);
  });

  it("省略可の値に null が入っている", () => {
    expect(() => parseShot({ ...shot, title: null })).toThrow(/shot\.title/);
  });

  it("列挙に無い値", () => {
    expect(() => parseShot({ ...shot, kind: "audio" })).toThrow(/shot\.kind/);
    expect(() => parseSearchEvent({ type: "progress" })).toThrow(/SearchEvent\.type/);
  });

  it("syncing に done が無い", () => {
    const source = { ...sources.sources[0], sync: { state: "syncing" } };
    expect(() => parseSources({ sources: [source] })).toThrow(/sync\.done/);
  });
});

describe("readSearchEvents", () => {
  it("chunk の境目で切れた行をつないで読む", async () => {
    const bytes = new TextEncoder().encode(searchNdjson);
    const cut = [0, 7, 300, 301, Math.floor(bytes.length / 2), bytes.length - 3, bytes.length];
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        for (let i = 1; i < cut.length; i++) controller.enqueue(bytes.slice(cut[i - 1], cut[i]));
        controller.close();
      },
    });
    const types: string[] = [];
    await readSearchEvents(body, (event) => types.push(event.type));
    expect(types).toEqual(searchLines.map((line) => (JSON.parse(line) as { type: string }).type));
  });
});
