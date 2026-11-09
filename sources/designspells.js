// sitemap.xml（Google video sitemap）が全件を新しい順に持つので、1 リクエストで取り切る。
const VIDEO = "http://www.google.com/schemas/sitemap-video/1.1";

defineSource({
  name: "Design Spells",
  home: "https://designspells.com/",
  login: null,

  async list() {
    const xml = new DOMParser().parseFromString(
      await mitate.text("/sitemap.xml"),
      "application/xml",
    );
    if (xml.querySelector("parsererror") || xml.documentElement.localName !== "urlset") {
      throw new Error("sitemap.xml を urlset として読めない");
    }
    const shots = [...xml.getElementsByTagName("url")]
      .map((entry) => [new URL(entry.getElementsByTagName("loc")[0].textContent.trim()), entry])
      .filter(([loc]) => loc.pathname.startsWith("/spells/"))
      .map(([loc, entry]) => toShot(loc, entry));
    if (shots.length === 0) throw new Error("sitemap.xml に spell が無い");
    return { shots, next: null };
  },
});

function toShot(loc, entry) {
  const values = (name) =>
    [...entry.getElementsByTagNameNS(VIDEO, name)].map((e) => e.textContent.trim());
  const [title] = values("title");
  const [description] = values("description");
  const [src] = values("content_loc");
  const [poster] = values("thumbnail_loc");
  // description は「A unique mobile easter egg in Arc. Discover this spell…」の定型文で、種類とアプリ名だけが中身。
  const [, type, app] =
    description?.match(/\b(?:mobile|desktop|tablet) (.+?) in (.+)\. Discover this spell/) ?? [];
  const tags = [...values("tag"), app, type?.replace(/\b\w/g, (c) => c.toUpperCase())];
  return {
    id: decodeURIComponent(loc.pathname.slice("/spells/".length)),
    url: loc.href,
    kind: "video",
    // sitemap に寸法が無いので、全件 16:9 だった first-frame の寸法を使う。
    media: { src, poster, width: 1920, height: 1080 },
    title,
    tags: [...new Set(tags.filter(Boolean))],
  };
}
