import { readFileSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

import { defineConfig, type Plugin } from "vite";

const here = import.meta.dirname;

export default defineConfig(({ command, mode }) => ({
  root: join(here, "web"),
  build: { outDir: "dist", emptyOutDir: true },
  // Panda の postcss plugin は postcss.config.mjs から読む。vite と postcss の版が違い、ここに直接書くと型が合わない
  css: { postcss: here },
  plugins: command === "serve" && mode !== "test" ? [devApi()] : [],
}));

function devApi(): Plugin {
  const api = process.env.MITATE_API;
  if (api === "mock") return mockApi();
  if (api !== undefined) throw new Error(`MITATE_API は mock か未指定にする: ${api}`);
  return appProxy();
}

function injectToken(token: string): Plugin["transformIndexHtml"] {
  return () => [
    {
      tag: "script",
      children: `window.__MITATE__ = ${JSON.stringify({ token })};`,
      injectTo: "head-prepend",
    },
  ];
}

/** 起動中のアプリへ /api と /media を中継する。アプリが WKWebView に注入する token を dev のページにも入れる */
function appProxy(): Plugin {
  const home = process.env.MITATE_HOME;
  if (home === "") throw new Error("MITATE_HOME が空");
  const path = join(home ?? join(homedir(), "Library/Application Support/Mitate"), "server.json");
  let info: unknown;
  try {
    info = JSON.parse(readFileSync(path, "utf8"));
  } catch (cause) {
    throw new Error(`${path} を読めない。アプリを起動するか MITATE_API=mock で開発する`, {
      cause,
    });
  }
  const { port, token } = (info ?? {}) as { port?: unknown; token?: unknown };
  if (typeof port !== "number" || typeof token !== "string") {
    throw new Error(`${path} に port と token が無い`);
  }
  const target = { target: `http://127.0.0.1:${port}`, changeOrigin: true };
  return {
    name: "mitate-app-proxy",
    config: () => ({ server: { proxy: { "/api": target, "/media": target } } }),
    transformIndexHtml: injectToken(token),
  };
}

type Json = Record<string, unknown>;

/** web/src/fixtures を返す API。応答は Swift の encoder が書いたものをそのまま流す */
function mockApi(): Plugin {
  const token = "mock";
  const fixture = (name: string) => readFileSync(join(here, "web/src/fixtures", name), "utf8");
  const lines = fixture("search.ndjson").split("\n").filter(Boolean);
  const shots = new Map<string, Json>();
  for (const line of [fixture("browse.json"), fixture("selection.json"), ...lines]) {
    for (const shot of ((JSON.parse(line) as Json).shots ?? []) as Json[]) {
      shots.set(shot.id as string, shot);
    }
  }
  const browse = (JSON.parse(fixture("browse.json")) as { shots: Json[] }).shots.map((s) => s.id);
  const selection = new Map<string, string | undefined>();
  for (const shot of (JSON.parse(fixture("selection.json")) as { shots: Json[] }).shots) {
    selection.set(shot.id as string, shot.note as string | undefined);
  }
  const inScope = (url: URL) => {
    const sources = url.searchParams.get("sources")?.split(",");
    return (shot: Json) => sources === undefined || sources.includes(shot.source as string);
  };
  /** fixture の Shot に、今の選択の印を付けて返す */
  const view = (id: unknown): Json => {
    const shot = shots.get(id as string);
    if (!shot) throw new Error(`fixture に無い Shot: ${String(id)}`);
    const { note: _note, ...rest } = shot;
    const note = selection.get(id as string);
    return { ...rest, selected: selection.has(id as string), ...(note ? { note } : {}) };
  };
  const known = (id: string | undefined) => id !== undefined && shots.has(id);
  const send = (res: ServerResponse, status: number, body?: unknown) => {
    res.statusCode = status;
    if (body === undefined) return res.end();
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(body));
  };
  const body = async (req: IncomingMessage) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    return Buffer.concat(chunks);
  };
  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  return {
    name: "mitate-mock-api",
    transformIndexHtml: injectToken(token),
    configureServer(server) {
      const respond = async (req: IncomingMessage, res: ServerResponse) => {
        if (req.headers.authorization !== `Bearer ${token}`) return send(res, 401);
        const url = new URL(req.url ?? "/", "http://mock");
        const [route, ...rest] = url.pathname.slice(1).split("/");
        const id = rest.length > 0 ? decodeURIComponent(rest.join("/")) : undefined;
        const at = `${req.method} ${route}`;
        if (at === "GET sources") return send(res, 200, JSON.parse(fixture("sources.json")));
        if (at === "GET browse") {
          const offset = Number(url.searchParams.get("offset") ?? 0);
          const limit = Number(url.searchParams.get("limit") ?? 80);
          const shots = browse.map(view).filter(inScope(url));
          return send(res, 200, { shots: shots.slice(offset, offset + limit) });
        }
        if (at === "GET search") {
          const live = url.searchParams.get("live") === "1";
          res.setHeader("Content-Type", "application/x-ndjson");
          for (const line of lines) {
            const event = JSON.parse(line) as Json;
            if (!live && (event.type === "live" || event.type === "error")) continue;
            if (event.source !== undefined && !inScope(url)(event)) continue;
            const shots = (event.shots as Json[] | undefined)?.map((s) => view(s.id));
            res.write(
              `${JSON.stringify(shots ? { ...event, shots: shots.filter(inScope(url)) } : event)}\n`,
            );
            await sleep(700);
          }
          return res.end();
        }
        if (at === "POST similar") {
          const target = (req.headers["content-type"] ?? "").startsWith("application/json")
            ? ((JSON.parse((await body(req)).toString()) as Json).id as string)
            : `${(await body(req)).length}`;
          const shift = [...target].reduce((sum, c) => sum + c.charCodeAt(0), 0) % browse.length;
          const order = [...browse.slice(shift), ...browse.slice(0, shift)];
          const shots = order.filter((s) => s !== target).map(view);
          return send(res, 200, { shots: shots.filter(inScope(url)) });
        }
        if (at === "GET shots" && known(id)) return send(res, 200, view(id));
        if (at === "GET selection")
          return send(res, 200, { shots: [...selection.keys()].map(view) });
        if (at === "PUT selection" && known(id)) {
          const update = JSON.parse((await body(req)).toString()) as Json;
          if (update.selected === true) selection.set(id as string, update.note as string);
          else selection.delete(id as string);
          return send(res, 200, view(id));
        }
        if (at === "DELETE selection") {
          selection.clear();
          return send(res, 204);
        }
        if (at === "POST sync" || at === "POST login") return send(res, 202);
        if (at === "POST open") {
          server.config.logger.info(`open ${(await body(req)).toString()}`);
          return send(res, 204);
        }
        if (at === "GET view" && known(id)) {
          const shot = view(id) as Json & { thumb?: string; media?: { src: string } };
          const upstream = await fetch(shot.thumb ?? (shot.media?.src as string));
          if (!upstream.ok) return send(res, 502);
          res.setHeader("Content-Type", "image/jpeg");
          return res.end(Buffer.from(await upstream.arrayBuffer()));
        }
        return send(res, 404);
      };
      server.middlewares.use("/api", async (req, res, next) => {
        try {
          await respond(req, res);
        } catch (error) {
          // ビューワーは引き直すたびに前の要求を取り消す。取り消された要求の失敗は流さない
          if (!req.destroyed) next(error);
        }
      });
    },
  };
}
