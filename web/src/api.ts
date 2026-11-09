// 形の正本は native/Sources/MitateCore/API.swift。Swift の encoder は nil を書かないので、省略可の値は「無い」か「その型」だけを受ける

export type ShotKind = "image" | "video" | "text";

export interface ShotMedia {
  src: string;
  poster?: string;
  width?: number;
  height?: number;
}

export interface ShotView {
  id: string;
  source: string;
  url: string;
  origin?: string;
  kind: ShotKind;
  title?: string;
  text?: string;
  tags: string[];
  author?: string;
  publishedAt?: string;
  thumb?: string;
  media?: ShotMedia;
  aspect?: number;
  colors: string[];
  duplicates: number;
  selected: boolean;
  note?: string;
}

export type LoginState = "none" | "signedIn" | "signedOut" | "unknown";

export type SyncState =
  | { state: "idle" }
  | { state: "syncing"; done: number }
  | { state: "failed"; message: string };

export interface SourceStatus {
  id: string;
  name: string;
  home: string;
  icon?: string;
  canList: boolean;
  canSearch: boolean;
  login: LoginState;
  count: number;
  sync: SyncState;
  lastSyncedAt?: string;
}

export type SearchEvent =
  | { type: "local"; shots: ShotView[] }
  | { type: "live"; source: string; shots: ShotView[] }
  | { type: "error"; source: string; message: string }
  | { type: "done" };

export interface SelectionUpdate {
  selected: boolean;
  note?: string;
}

type Json = Record<string, unknown>;
type Is<T> = (value: unknown) => value is T;

const isString: Is<string> = (v) => typeof v === "string";
const isNumber: Is<number> = (v): v is number => typeof v === "number" && Number.isFinite(v);
const isInt: Is<number> = (v): v is number => Number.isInteger(v);
const isBoolean: Is<boolean> = (v) => typeof v === "boolean";
const oneOf =
  <const T extends string>(...values: T[]): Is<T> =>
  (v): v is T =>
    values.includes(v as T);

function record(value: unknown, at: string): Json {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError(`${at} がオブジェクトではない: ${JSON.stringify(value)}`);
  }
  return value as Json;
}

function required<T>(o: Json, key: string, is: Is<T>, at: string): T {
  const value = o[key];
  if (!is(value)) throw new TypeError(`${at}.${key} の形が違う: ${JSON.stringify(value)}`);
  return value;
}

function optional<T>(o: Json, key: string, is: Is<T>, at: string): T | undefined {
  return o[key] === undefined ? undefined : required(o, key, is, at);
}

function list<T>(value: unknown, at: string, parse: (item: unknown, at: string) => T): T[] {
  if (!Array.isArray(value)) throw new TypeError(`${at} が配列ではない: ${JSON.stringify(value)}`);
  return value.map((item, i) => parse(item, `${at}[${i}]`));
}

function parseMedia(value: unknown, at: string): ShotMedia {
  const o = record(value, at);
  return {
    src: required(o, "src", isString, at),
    poster: optional(o, "poster", isString, at),
    width: optional(o, "width", isNumber, at),
    height: optional(o, "height", isNumber, at),
  };
}

export function parseShot(value: unknown, at = "shot"): ShotView {
  const o = record(value, at);
  return {
    id: required(o, "id", isString, at),
    source: required(o, "source", isString, at),
    url: required(o, "url", isString, at),
    origin: optional(o, "origin", isString, at),
    kind: required(o, "kind", oneOf("image", "video", "text"), at),
    title: optional(o, "title", isString, at),
    text: optional(o, "text", isString, at),
    tags: list(o.tags, `${at}.tags`, (v, a) => required({ v }, "v", isString, a)),
    author: optional(o, "author", isString, at),
    publishedAt: optional(o, "publishedAt", isString, at),
    thumb: optional(o, "thumb", isString, at),
    media: o.media === undefined ? undefined : parseMedia(o.media, `${at}.media`),
    aspect: optional(o, "aspect", isNumber, at),
    colors: list(o.colors, `${at}.colors`, (v, a) => required({ v }, "v", isString, a)),
    duplicates: required(o, "duplicates", isInt, at),
    selected: required(o, "selected", isBoolean, at),
    note: optional(o, "note", isString, at),
  };
}

export function parseShots(value: unknown, at = "ShotsResponse"): ShotView[] {
  return list(record(value, at).shots, `${at}.shots`, parseShot);
}

function parseSync(value: unknown, at: string): SyncState {
  const o = record(value, at);
  const state = required(o, "state", oneOf("idle", "syncing", "failed"), at);
  if (state === "syncing") return { state, done: required(o, "done", isInt, at) };
  if (state === "failed") return { state, message: required(o, "message", isString, at) };
  return { state };
}

function parseSource(value: unknown, at: string): SourceStatus {
  const o = record(value, at);
  return {
    id: required(o, "id", isString, at),
    name: required(o, "name", isString, at),
    home: required(o, "home", isString, at),
    icon: optional(o, "icon", isString, at),
    canList: required(o, "canList", isBoolean, at),
    canSearch: required(o, "canSearch", isBoolean, at),
    login: required(o, "login", oneOf("none", "signedIn", "signedOut", "unknown"), at),
    count: required(o, "count", isInt, at),
    sync: parseSync(o.sync, `${at}.sync`),
    lastSyncedAt: optional(o, "lastSyncedAt", isString, at),
  };
}

export function parseSources(value: unknown): SourceStatus[] {
  return list(record(value, "SourcesResponse").sources, "SourcesResponse.sources", parseSource);
}

export function parseSearchEvent(value: unknown, at = "SearchEvent"): SearchEvent {
  const o = record(value, at);
  const type = required(o, "type", oneOf("local", "live", "error", "done"), at);
  if (type === "local") return { type, shots: list(o.shots, `${at}.shots`, parseShot) };
  if (type === "live") {
    return {
      type,
      source: required(o, "source", isString, at),
      shots: list(o.shots, `${at}.shots`, parseShot),
    };
  }
  if (type === "error") {
    return {
      type,
      source: required(o, "source", isString, at),
      message: required(o, "message", isString, at),
    };
  }
  return { type };
}

/** NDJSON の本文を 1 行ずつ SearchEvent にして渡す。行が chunk の境目で切れていてもつなぐ */
export async function readSearchEvents(
  body: ReadableStream<Uint8Array>,
  onEvent: (event: SearchEvent) => void,
): Promise<void> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const flush = (line: string) => {
    if (line.trim() !== "") onEvent(parseSearchEvent(JSON.parse(line)));
  };
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    // stream を付けないと、chunk の境目で切れた多バイト文字が壊れる
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    lines.forEach(flush);
  }
  flush(buffer + decoder.decode());
}

declare global {
  interface Window {
    __MITATE__?: { token?: unknown };
  }
}

function authToken(): string {
  const token = window.__MITATE__?.token;
  if (typeof token !== "string" || token === "") {
    throw new Error("window.__MITATE__.token が無い");
  }
  return token;
}

interface CallOptions {
  body?: BodyInit;
  type?: string;
  signal?: AbortSignal;
}

async function call(method: string, path: string, options: CallOptions = {}): Promise<Response> {
  const headers: Record<string, string> = { Authorization: `Bearer ${authToken()}` };
  if (options.type) headers["Content-Type"] = options.type;
  const res = await fetch(path, { method, headers, body: options.body, signal: options.signal });
  if (!res.ok) throw new Error(`${method} ${path} が ${res.status} を返した`);
  return res;
}

const sendJson = (value: unknown) => ({ body: JSON.stringify(value), type: "application/json" });

function query(params: Record<string, string | number | undefined>): string {
  const q = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) q.set(key, String(value));
  }
  const text = q.toString();
  return text ? `?${text}` : "";
}

const shotPath = (base: string, id: string) => `${base}/${encodeURIComponent(id)}`;

/** sources は source id をカンマでつないだもの。undefined なら全サイト */
export interface Scope {
  sources?: string;
  signal?: AbortSignal;
}

export async function getSources(signal?: AbortSignal): Promise<SourceStatus[]> {
  return parseSources(await (await call("GET", "/api/sources", { signal })).json());
}

export async function browse(offset: number, limit: number, scope: Scope): Promise<ShotView[]> {
  const path = `/api/browse${query({ sources: scope.sources, offset, limit })}`;
  return parseShots(await (await call("GET", path, scope)).json());
}

export async function search(
  q: string,
  live: boolean,
  scope: Scope,
  onEvent: (event: SearchEvent) => void,
): Promise<void> {
  const path = `/api/search${query({ q, sources: scope.sources, live: live ? 1 : undefined })}`;
  const res = await call("GET", path, scope);
  if (!res.body) throw new Error(`GET ${path} に本文が無い`);
  await readSearchEvents(res.body, onEvent);
}

export type SimilarTarget = { id: string } | Blob;

export async function similar(target: SimilarTarget, scope: Scope): Promise<ShotView[]> {
  const body = target instanceof Blob ? { body: target, type: target.type } : sendJson(target);
  const res = await call("POST", `/api/similar${query({ sources: scope.sources })}`, {
    ...body,
    signal: scope.signal,
  });
  return parseShots(await res.json());
}

export async function getShot(id: string, signal?: AbortSignal): Promise<ShotView> {
  return parseShot(await (await call("GET", shotPath("/api/shots", id), { signal })).json());
}

export async function getSelection(): Promise<ShotView[]> {
  return parseShots(await (await call("GET", "/api/selection")).json());
}

export async function setSelection(id: string, update: SelectionUpdate): Promise<ShotView> {
  const res = await call("PUT", shotPath("/api/selection", id), sendJson(update));
  return parseShot(await res.json());
}

export async function clearSelection(): Promise<void> {
  await call("DELETE", "/api/selection");
}

export async function login(source: string): Promise<void> {
  await call("POST", `/api/login${query({ source })}`);
}

export async function openInBrowser(url: string): Promise<void> {
  await call("POST", "/api/open", sendJson({ url }));
}

export async function viewImage(id: string): Promise<Blob> {
  return (await call("GET", shotPath("/api/view", id))).blob();
}
