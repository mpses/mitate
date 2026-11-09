// 全件がトップの HTML 1 枚に入っているので、list は 1 ページで終わる。
defineSource({
  name: "Design Engineer Tools",
  home: "https://designengineer.tools/",
  login: null,

  async list() {
    const html = await mitate.text("https://designengineer.tools/");
    const tools = parseTools(html);
    // RSC の構造が変わって取りこぼしたら、欠けた一覧を成功扱いにしない。
    const drawn = html.match(/class="grid_tool__/g)?.length ?? 0;
    if (tools.length === 0 || tools.length !== drawn) {
      throw new Error(`RSC から ${tools.length} 件、HTML には ${drawn} 件で一致しない`);
    }
    return { shots: tools.map(toShot), next: null };
  },
});

function toShot(t) {
  return {
    id: t.id,
    url: `https://designengineer.tools/#${t.id}`,
    origin: t.href,
    kind: "text",
    title: t.name,
    text: `${t.category} · ${new URL(t.href).host}`,
    tags: [t.category],
  };
}

function parseTools(html) {
  let stream = "";
  for (const m of html.matchAll(/self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)/g))
    stream += JSON.parse(m[1]);
  const rows = new Map();
  for (const line of stream.split("\n")) {
    const m = line.match(/^([0-9a-f]+):([[{].*)$/);
    if (m) rows.set(m[1], JSON.parse(m[2]));
  }
  const seen = new Set(["0"]);
  const tools = [];
  // 区分と項目は CSS Modules の接頭辞でしか見分けられない。項目の React key が Sanity の _id。
  walk(rows, rows.get("0"), seen, (n) => {
    if (!n[3].className?.startsWith("grid_category__")) return;
    let category = null;
    walk(rows, n[3].children, seen, (c) => {
      if (c[1] === "h2") category = c[3].children;
      if (!c[3].className?.startsWith("grid_tool__")) return;
      let a = null;
      walk(rows, c[3].children, seen, (x) => {
        if (x[1] === "a") a = x[3];
      });
      if (!c[2] || !a?.href || typeof category !== "string")
        throw new Error(`項目の形が想定と違う: ${JSON.stringify(c).slice(0, 200)}`);
      const name = [a.children]
        .flat()
        .filter((s) => typeof s === "string")
        .join("")
        .trim();
      tools.push({ id: c[2], name, href: a.href, category });
      return false;
    });
    return false;
  });
  return tools;
}

// RSC の要素は ["$", type, key, props] で、子が別の行へ "$L<id>" で分かれることがある。
function walk(rows, node, seen, visit) {
  if (typeof node === "string") {
    const id = node.match(/^\$L?([0-9a-f]+)$/)?.[1];
    if (id && rows.has(id) && !seen.has(id)) {
      seen.add(id);
      walk(rows, rows.get(id), seen, visit);
    }
  } else if (
    Array.isArray(node) &&
    node[0] === "$" &&
    typeof node[1] === "string" &&
    node[3] &&
    typeof node[3] === "object"
  ) {
    if (visit(node) !== false) walk(rows, node[3].children, seen, visit);
  } else if (node && typeof node === "object") {
    for (const v of Object.values(node)) walk(rows, v, seen, visit);
  }
}
