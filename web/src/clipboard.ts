import { viewImage, type ShotView } from "./api";
import { selectionMarkdown } from "./markdown";

async function toPng(image: Blob): Promise<Blob> {
  const bitmap = await createImageBitmap(image);
  const canvas = document.createElement("canvas");
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("canvas の 2d context を得られない");
  context.drawImage(bitmap, 0, 0);
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (png) => (png ? resolve(png) : reject(new Error("canvas を PNG にできない"))),
      "image/png",
    );
  });
}

/** 画像をクリップボードへ写す。文字の Shot は画像が無いので Markdown で写す */
export async function copyShot(shot: ShotView): Promise<void> {
  if (shot.kind === "text") return navigator.clipboard.writeText(selectionMarkdown([shot]));
  // Safari は await の後の write をユーザー操作の外とみなす。Promise のまま ClipboardItem に渡す
  const png = viewImage(shot.id).then(toPng);
  await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
}

export const copySelection = (shots: readonly ShotView[]) =>
  navigator.clipboard.writeText(selectionMarkdown(shots));
