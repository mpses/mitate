// Mitate.app を組み立てて ~/Applications に置き、埋め込みモデルを取り、CLI・skill・MCP を登録する。何度実行しても同じ状態になる。
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { semanticTokens } from "@bakutan-org/design-tokens";

const appDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.resolve(appDir, "../..");
const nativeDir = path.join(appDir, "native");
const home = os.homedir();
const xcode = "/Applications/Xcode.app/Contents/Developer";
const bundleId = "org.bakutan.mitate";
const version = JSON.parse(fs.readFileSync(path.join(appDir, "package.json"), "utf8")).version;

const target = path.join(home, "Applications", "Mitate.app");
const executable = path.join(target, "Contents", "MacOS", "Mitate");
const dataDir = path.join(home, "Library", "Application Support", "Mitate");

if (!fs.existsSync(xcode)) throw new Error(`Xcode が無い: ${xcode}`);
// Command Line Tools の swift は modulemap が重複していて壊れているので、Xcode のツールチェーンを使う。
const env = { ...process.env, DEVELOPER_DIR: xcode };

function run(cmd, args, options = {}) {
  console.log(`$ ${cmd} ${args.join(" ")}`);
  execFileSync(cmd, args, { stdio: "inherit", env, ...options });
}

function output(cmd, args, options = {}) {
  return execFileSync(cmd, args, { env, encoding: "utf8", ...options }).trim();
}

function step(name) {
  console.log(`\n== ${name}`);
}

step("ビューワーとネイティブのビルド");
run("pnpm", ["--filter", "@bakutan-org/mitate", "build"], { cwd: repo });
const webDist = path.join(appDir, "web", "dist");
if (!fs.existsSync(path.join(webDist, "index.html")))
  throw new Error(`ビューワーの build 結果が無い: ${webDist}`);
run("swift", ["build", "-c", "release", "--package-path", nativeDir]);
const binary = path.join(
  output("swift", ["build", "-c", "release", "--package-path", nativeDir, "--show-bin-path"]),
  "Mitate",
);

step(".app の組み立て");
const staging = path.join(nativeDir, ".build", "Mitate.app");
fs.rmSync(staging, { recursive: true, force: true });
const contents = path.join(staging, "Contents");
const resources = path.join(contents, "Resources");
fs.mkdirSync(path.join(contents, "MacOS"), { recursive: true });
fs.mkdirSync(path.join(resources, "sources"), { recursive: true });
fs.copyFileSync(binary, path.join(contents, "MacOS", "Mitate"));
for (const file of fs.readdirSync(path.join(appDir, "sources"))) {
  if (file.endsWith(".js"))
    fs.copyFileSync(path.join(appDir, "sources", file), path.join(resources, "sources", file));
}
fs.cpSync(webDist, path.join(resources, "web"), { recursive: true });
// アプリは起動時に Resources/models.json の dir から <データの置き場>/models/<dir> を読む。
fs.copyFileSync(path.join(appDir, "models.json"), path.join(resources, "models.json"));
buildIcon(path.join(resources, "AppIcon.icns"));
fs.writeFileSync(path.join(contents, "Info.plist"), infoPlist());
run("codesign", ["--force", "--sign", "-", "--timestamp=none", staging]);

step("埋め込みモデル");
// 揃っているファイルは sha256 を照合するだけで取り直さない。
run("node", [path.join(appDir, "scripts", "models.mjs"), dataDir]);

step("起動中のアプリを止めて置き換える");
stopRunningApp();
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.rmSync(target, { recursive: true, force: true });
run("ditto", [staging, target]);

step("CLI");
const cli = path.join(home, ".local", "bin", "mitate");
fs.mkdirSync(path.dirname(cli), { recursive: true });
fs.rmSync(cli, { force: true });
fs.symlinkSync(executable, cli);
console.log(`${cli} → ${executable}`);

// Claude Code は設定の置き場（CLAUDE_CONFIG_DIR）ごとに skill と MCP を持つ。既定の ~/.claude と、使われている ~/.claude-*（.claude.json がある）のすべてに入れる。
const defaultEnv = { ...env };
delete defaultEnv.CLAUDE_CONFIG_DIR;
const claudeConfigs = [
  { dir: path.join(home, ".claude"), env: defaultEnv },
  ...fs
    .readdirSync(home, { withFileTypes: true })
    .filter((e) => e.isDirectory() && e.name.startsWith(".claude-"))
    .map((e) => path.join(home, e.name))
    .filter((dir) => fs.existsSync(path.join(dir, ".claude.json")))
    .map((dir) => ({ dir, env: { ...defaultEnv, CLAUDE_CONFIG_DIR: dir } })),
];

step("skill");
const skill = path.join(home, ".agents", "skills", "mitate");
fs.rmSync(skill, { recursive: true, force: true });
fs.cpSync(path.join(appDir, "skill"), skill, { recursive: true });
for (const dir of [
  ...claudeConfigs.map((c) => path.join(c.dir, "skills")),
  path.join(home, ".codex", "skills"),
]) {
  if (!fs.existsSync(dir)) throw new Error(`skill の置き場が無い: ${dir}`);
  const link = path.join(dir, "mitate");
  fs.rmSync(link, { recursive: true, force: true });
  fs.symlinkSync(skill, link);
  console.log(`${link} → ${skill}`);
}

step("MCP");
for (const config of claudeConfigs) {
  console.log(`Claude Code: ${config.dir}`);
  if (
    spawnSync("claude", ["mcp", "get", "mitate"], { env: config.env, stdio: "ignore" }).status === 0
  ) {
    run("claude", ["mcp", "remove", "-s", "user", "mitate"], { env: config.env });
  }
  run("claude", ["mcp", "add", "-s", "user", "mitate", "--", executable, "mcp"], {
    env: config.env,
  });
}
if (spawnSync("codex", ["mcp", "get", "mitate"], { env, stdio: "ignore" }).status === 0) {
  run("codex", ["mcp", "remove", "mitate"]);
}
run("codex", ["mcp", "add", "mitate", "--", executable, "mcp"]);

step("起動");
run("open", [target]);
console.log(`\nMitate ${version} を ${target} に入れた。`);

function buildIcon(out) {
  const iconset = path.join(nativeDir, ".build", "AppIcon.iconset");
  fs.rmSync(iconset, { recursive: true, force: true });
  fs.mkdirSync(iconset, { recursive: true });
  const master = path.join(iconset, "master.png");
  const { brand, bg, focus } = semanticTokens.colors;
  run("swift", [
    path.join(appDir, "scripts", "icon.swift"),
    brand.primary,
    bg.default,
    focus.default,
    master,
  ]);
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      const name = scale === 1 ? `icon_${size}x${size}.png` : `icon_${size}x${size}@2x.png`;
      run(
        "sips",
        [
          "-z",
          String(size * scale),
          String(size * scale),
          master,
          "--out",
          path.join(iconset, name),
        ],
        { stdio: "ignore" },
      );
    }
  }
  fs.rmSync(master);
  run("iconutil", ["-c", "icns", iconset, "-o", out]);
}

function infoPlist() {
  const entries = {
    CFBundleIdentifier: bundleId,
    CFBundleName: "Mitate",
    CFBundleDisplayName: "Mitate",
    CFBundleExecutable: "Mitate",
    CFBundleIconFile: "AppIcon",
    CFBundlePackageType: "APPL",
    CFBundleShortVersionString: version,
    CFBundleVersion: version,
    LSMinimumSystemVersion: "15.0",
    LSApplicationCategoryType: "public.app-category.graphics-design",
    NSHighResolutionCapable: true,
    // libmalloc は放した大きな領域を dirty のまま cache に残し、埋め込みの session を放しても footprint が下がらない。
    LSEnvironment: { MallocLargeCache: "0" },
  };
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n${plistValue(entries, "")}\n</plist>\n`;
}

function plistValue(value, indent) {
  if (typeof value === "boolean") return `<${value}/>`;
  if (typeof value === "string") return `<string>${value}</string>`;
  if (typeof value === "object" && value !== null) {
    const inner = `${indent}  `;
    const body = Object.entries(value)
      .map(([key, v]) => `${inner}<key>${key}</key>\n${inner}${plistValue(v, inner)}`)
      .join("\n");
    return `<dict>\n${body}\n${indent}</dict>`;
  }
  throw new Error(`Info.plist に書けない値: ${JSON.stringify(value)}`);
}

function stopRunningApp() {
  const info = path.join(dataDir, "server.json");
  if (!fs.existsSync(info)) return;
  const { pid } = JSON.parse(fs.readFileSync(info, "utf8"));
  try {
    process.kill(pid, "SIGTERM");
  } catch (error) {
    if (error.code === "ESRCH") return;
    throw error;
  }
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch {
      return;
    }
    spawnSync("sleep", ["0.2"]);
  }
  throw new Error(`起動中の Mitate（pid ${pid}）が 10 秒以内に終わらない`);
}
