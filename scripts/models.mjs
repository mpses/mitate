// models.json の埋め込みモデルを <データの置き場>/models/<dir>/ へ取り、sha256 を照合する。揃っているファイルは取り直さない。
// externalData を持つ ONNX は、取った後に初期値を <path>_data へ出した形に変え、変えた後の 2 つのファイルも照合する。
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

const manifestFile = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "models.json",
);

/** ONNX Runtime は、ページの境界に揃った外の初期値を mmap で読む。そのページは clean なのでプロセスの footprint に数えない */
const ALIGN = 16384;
/** onnx の external data の変換と同じく、これより小さい初期値は graph に残す */
const MIN_EXTERNAL_BYTES = 1024;

const args = process.argv.slice(2);
if (args.length !== 1)
  throw new Error("使い方: node apps/mitate/scripts/models.mjs <データの置き場>");
const manifest = readManifest(manifestFile);
const dir = path.join(path.resolve(args[0]), "models", manifest.dir);

for (const file of manifest.files) {
  const dest = resolveInside(dir, file.path);
  if (file.externalData) {
    await ensureExternal(dest, file);
    continue;
  }
  if (fs.existsSync(dest)) {
    await verify(dest, file);
    console.log(`揃っている: ${file.path}`);
    continue;
  }
  await download(`${manifest.source}/${file.path}`, dest, file);
}
console.log(`置き先: ${dir}`);

function readManifest(file) {
  const m = JSON.parse(fs.readFileSync(file, "utf8"));
  const fail = (what) => {
    throw new Error(`${file} の ${what} が不正`);
  };
  const checkDigest = (d, what) => {
    if (!Number.isSafeInteger(d?.bytes) || d.bytes <= 0) fail(`${what} の bytes`);
    if (typeof d.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(d.sha256)) fail(`${what} の sha256`);
  };
  if (typeof m.source !== "string" || !m.source.startsWith("https://") || m.source.endsWith("/"))
    fail("source");
  if (typeof m.dir !== "string" || m.dir === "" || m.dir.includes("/") || m.dir.startsWith("."))
    fail("dir");
  if (!Array.isArray(m.files) || m.files.length === 0) fail("files");
  for (const f of m.files) {
    if (typeof f.path !== "string" || f.path === "") fail("files[].path");
    checkDigest(f, f.path);
    if (f.externalData !== undefined) {
      if (!f.path.endsWith(".onnx")) fail(`${f.path} の externalData（.onnx にだけ付ける）`);
      checkDigest(f.externalData.graph, `${f.path} の externalData.graph`);
      checkDigest(f.externalData.data, `${f.path} の externalData.data`);
    }
  }
  return m;
}

function resolveInside(root, relative) {
  const full = path.resolve(root, relative);
  if (!full.startsWith(root + path.sep)) throw new Error(`${relative} が ${root} の外を指す`);
  return full;
}

async function sha256(file) {
  const hash = createHash("sha256");
  await pipeline(fs.createReadStream(file), hash);
  return hash.digest("hex");
}

/** 大きさと sha256 が一致すれば null、違えばその説明 */
async function mismatch(file, expected) {
  const bytes = fs.statSync(file).size;
  const digest = bytes === expected.bytes ? await sha256(file) : null;
  if (digest === expected.sha256) return null;
  return `${bytes} バイト、sha256 ${digest ?? "未計算"}。期待は ${expected.bytes} バイト、${expected.sha256}`;
}

async function verify(file, expected) {
  const reason = await mismatch(file, expected);
  if (reason === null) return;
  fs.rmSync(file);
  throw new Error(
    `${file} が models.json と合わないので消した（${reason}）。もう一度実行すると取り直す`,
  );
}

async function download(url, dest, expected) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const part = `${dest}.part`;
  const started = Date.now();
  console.log(`取得: ${expected.path}（${(expected.bytes / 1e6).toFixed(1)} MB）`);
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`${url} を取れない: HTTP ${res.status}`);
  await pipeline(Readable.fromWeb(res.body), fs.createWriteStream(part));
  try {
    await verify(part, expected);
  } catch (error) {
    throw new Error(`${url} の中身が models.json と合わない`, { cause: error });
  }
  fs.renameSync(part, dest);
  console.log(`  ${((Date.now() - started) / 1000).toFixed(1)} 秒`);
}

// MARK: - 初期値を外へ出した ONNX

/**
 * dest に初期値を外へ出した ONNX（graph）、dest_data に初期値を置く。
 * 揃っていなければ、取ったままの形（dest にあればそれ、無ければ取り直す）から変える。
 */
async function ensureExternal(dest, file) {
  const data = `${dest}_data`;
  const { graph: graphDigest, data: dataDigest } = file.externalData;
  if (
    fs.existsSync(dest) &&
    fs.existsSync(data) &&
    (await mismatch(dest, graphDigest)) === null &&
    (await mismatch(data, dataDigest)) === null
  ) {
    console.log(`揃っている: ${file.path}（初期値は ${path.basename(data)}）`);
    return;
  }
  if (fs.existsSync(dest)) await verify(dest, file);
  else await download(`${manifest.source}/${file.path}`, dest, file);

  console.log(`初期値を外へ出す: ${file.path}`);
  const graphPart = `${dest}.graph.part`;
  const dataPart = `${data}.part`;
  externalize(dest, graphPart, dataPart, path.basename(data));
  for (const [part, digest, name] of [
    [graphPart, graphDigest, "externalData.graph"],
    [dataPart, dataDigest, "externalData.data"],
  ]) {
    const reason = await mismatch(part, digest);
    if (reason !== null) {
      fs.rmSync(graphPart, { force: true });
      fs.rmSync(dataPart, { force: true });
      throw new Error(`${file.path} を変えた結果が models.json の ${name} と合わない（${reason}）`);
    }
  }
  // 初期値を先に置く。graph を置き換える前に止まっても、dest は取ったままの形で残る
  fs.renameSync(dataPart, data);
  fs.renameSync(graphPart, dest);
}

/**
 * ModelProto の graph.initializer のうち raw_data を持つものを、raw_data の代わりに
 * external_data（location・offset・length）と data_location = EXTERNAL を持つ形にする。ほかの欄はバイト列のまま写す。
 */
function externalize(source, graphOut, dataOut, location) {
  const model = fs.readFileSync(source);
  const fd = fs.openSync(dataOut, "w");
  let offset = 0;
  try {
    const tensor = (start, end) => {
      const all = [...fields(model, start, end)];
      const raw = all.find((f) => f.field === 9 && f.wire === 2);
      if (!raw || raw.end - raw.valueStart < MIN_EXTERNAL_BYTES) return model.subarray(start, end);
      const length = raw.end - raw.valueStart;
      offset = Math.ceil(offset / ALIGN) * ALIGN;
      fs.writeSync(fd, model, raw.valueStart, length, offset);
      const kept = all
        .filter((f) => f !== raw && f.field !== 13 && f.field !== 14)
        .map((f) => model.subarray(f.keyStart, f.end));
      const entry = (key, value) =>
        lengthDelimited(
          13,
          Buffer.concat([
            lengthDelimited(1, Buffer.from(key)),
            lengthDelimited(2, Buffer.from(value)),
          ]),
        );
      const external = [
        entry("location", location),
        entry("offset", String(offset)),
        entry("length", String(length)),
        // TensorProto.data_location = EXTERNAL
        Buffer.concat([varint(14 * 8), varint(1)]),
      ];
      offset += length;
      return Buffer.concat([...kept, ...external]);
    };
    // GraphProto.initializer（5 番）だけを書き換える
    const graph = (start, end) =>
      Buffer.concat(
        [...fields(model, start, end)].map((f) =>
          f.field === 5 && f.wire === 2
            ? lengthDelimited(5, tensor(f.valueStart, f.end))
            : model.subarray(f.keyStart, f.end),
        ),
      );
    // ModelProto.graph（7 番）
    const out = Buffer.concat(
      [...fields(model, 0, model.length)].map((f) =>
        f.field === 7 && f.wire === 2
          ? lengthDelimited(7, graph(f.valueStart, f.end))
          : model.subarray(f.keyStart, f.end),
      ),
    );
    if (offset === 0) throw new Error(`${source} に外へ出す初期値が無い`);
    fs.writeFileSync(graphOut, out);
  } finally {
    fs.closeSync(fd);
  }
}

/** protobuf の欄を前から順に返す。keyStart から end までがその欄のバイト列、長さ付きの欄の中身は valueStart から */
function* fields(buf, start, end) {
  let at = start;
  while (at < end) {
    const keyStart = at;
    const [key, afterKey] = readVarint(buf, at);
    const field = Math.floor(key / 8);
    const wire = key % 8;
    let valueStart = afterKey;
    let valueEnd;
    if (wire === 0) valueEnd = readVarint(buf, afterKey)[1];
    else if (wire === 1) valueEnd = afterKey + 8;
    else if (wire === 5) valueEnd = afterKey + 4;
    else if (wire === 2) {
      const [length, afterLength] = readVarint(buf, afterKey);
      valueStart = afterLength;
      valueEnd = afterLength + length;
    } else throw new Error(`${keyStart} バイト目の wire type ${wire} は読めない`);
    if (valueEnd > end) throw new Error(`${keyStart} バイト目の欄が親のメッセージの外へはみ出す`);
    yield { field, wire, keyStart, valueStart, end: valueEnd };
    at = valueEnd;
  }
}

function readVarint(buf, at) {
  let value = 0;
  for (let shift = 0; shift < 64; shift += 7) {
    if (at >= buf.length) throw new Error(`${at} バイト目で varint が途中で終わった`);
    const byte = buf[at++];
    value += (byte & 0x7f) * 2 ** shift;
    if (byte < 0x80) {
      if (!Number.isSafeInteger(value)) throw new Error(`${at} バイト目の varint が大きすぎる`);
      return [value, at];
    }
  }
  throw new Error(`${at} バイト目の varint が長すぎる`);
}

function varint(value) {
  const bytes = [];
  let rest = value;
  while (rest >= 0x80) {
    bytes.push((rest % 0x80) | 0x80);
    rest = Math.floor(rest / 0x80);
  }
  bytes.push(rest);
  return Buffer.from(bytes);
}

function lengthDelimited(field, body) {
  return Buffer.concat([varint(field * 8 + 2), varint(body.length), body]);
}
