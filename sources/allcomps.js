// All Components は全件を 1 つの JSON で配っているので、list は 1 ページで全件を返す。
// robots.txt は /r/ を Disallow にしているが、サイトの /llms.txt がエージェント向けにこの JSON を案内している。
// preview は iframe のライブ描画だけで静止画が無いので、説明文を主役にした text の Shot にする。
// トップはその iframe を並べ、隠しタブが 600MB を超えるので、iframe の無いライブラリの一覧を開く。
defineSource({
  name: "All Components",
  home: "https://allcomps.vercel.app/sources",
  login: null,

  async list() {
    const items = (await mitate.json("/r/registry.json"))?.items;
    if (!Array.isArray(items) || items.length === 0)
      throw new Error("registry.json に items が無い");
    const docsCount = new Map();
    for (const item of items)
      docsCount.set(item.meta.docsUrl, (docsCount.get(item.meta.docsUrl) ?? 0) + 1);
    return { shots: items.map((item) => toShot(item, docsCount)), next: null };
  },
});

function toShot(item, docsCount) {
  const id = item.name.replace("--", "/");
  const { library, category, docsUrl } = item.meta;
  return {
    id,
    url: mitate.abs(`/c/${id}`),
    // 複数の部品が同じ docsUrl を持つときはライブラリのトップを指しているので、原典にしない。
    origin: docsCount.get(docsUrl) === 1 ? docsUrl : undefined,
    kind: "text",
    title: item.title,
    text: [item.description, `${library} · ${category}`].filter(Boolean).join("\n"),
    tags: item.categories ?? [],
    author: library,
  };
}
