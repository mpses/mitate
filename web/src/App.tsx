import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

import { Icon } from "@bakutan-org/ui";
import { css, cva } from "@bakutan-org/ui/styled-system/css";

import {
  clearSelection,
  getSelection,
  login,
  openInBrowser,
  setSelection,
  type ShotView,
  type SourceStatus,
} from "./api";
import { copySelection, copyShot } from "./clipboard";
import { useSources, useWall } from "./data";
import { columnWidths, loadDensity, saveDensity, stepDensity } from "./density";
import { dragOut, draggingOut } from "./drag";
import { clearFailure, useFailed } from "./failure";
import { Header } from "./Header";
import { back, commit, current, edit, forward, initialHistory, push, type Query } from "./history";
import { keyCommand, type Command, type FocusArea } from "./keys";
import { Lightbox, type LightboxTarget } from "./Lightbox";
import { ShotWall, type ShotWallHandle } from "./ShotWall";
import { useStableCallback } from "./stable";
import { shotAt } from "./Tile";
import { Tray } from "./Tray";

/** 打つのを止めてから引き直すまでの待ち */
const SEARCH_DEBOUNCE_MS = 120;

const styles = {
  app: css({ bg: "bg.default", minH: "100dvh" }),
  // 選択の列が出ている間は、壁の末尾が列の下に隠れないよう下を空ける
  main: cva({
    base: { pt: "2", px: "4" },
    variants: { tray: { true: { pb: "24" }, false: { pb: "4" } } },
  }),
  // 結果が無いときは、壁の位置に印を 1 つだけ置く
  empty: css({
    color: "text.disabled",
    display: "flex",
    justifyContent: "center",
    pt: "24",
  }),
  drop: css({
    inset: "0",
    outline: "2px solid",
    outlineColor: "focus.default",
    outlineOffset: "-2px",
    pointerEvents: "none",
    position: "fixed",
    zIndex: 40,
  }),
};

/**
 * 焦点表示が見せているもの。壁から開いたときは Shot を id で引き直し、壁が差し替わっても同じ Shot を見せ続ける。
 * それ以外（選択の列、近いものの壁）は開いた時点の並び
 */
type Opened =
  | { list: "wall"; shot: ShotView; from?: DOMRect }
  | { list: readonly ShotView[]; index: number; from?: DOMRect };

const imageIn = (data: DataTransfer | null) =>
  [...(data?.files ?? [])].find((file) => file.type.startsWith("image/"));

/** 履歴から外れた種の画像の object URL を解放する */
function useRevokeDroppedPreviews(entries: readonly Query[]) {
  const previews = useRef(new Set<string>());
  useEffect(() => {
    const now = new Set(
      entries.flatMap((query) => (query.seed?.type === "image" ? [query.seed.preview] : [])),
    );
    for (const url of previews.current) if (!now.has(url)) URL.revokeObjectURL(url);
    previews.current = now;
  }, [entries]);
}

export function App() {
  const input = useRef<HTMLInputElement>(null);
  const masonry = useRef<ShotWallHandle>(null);

  const [sources, refreshSources] = useSources();
  const sourceMap = useMemo(() => new Map(sources.map((s) => [s.id, s])), [sources]);
  const [excluded, setExcluded] = useState<ReadonlySet<string>>(new Set());
  const scope =
    excluded.size === 0
      ? undefined
      : sources
          .filter((s) => !excluded.has(s.id))
          .map((s) => s.id)
          .join(",");

  const [history, setHistory] = useState(initialHistory);
  const query = current(history);
  const [text, setText] = useState("");
  const typing = useRef<number>(undefined);
  const [liveRun, setLiveRun] = useState<{ query: Query }>();
  const live = liveRun?.query === query ? liveRun : undefined;
  useRevokeDroppedPreviews(history.entries);

  const { wall, loadMore, shuffle } = useWall({
    query,
    scope,
    live,
    stock: sources.reduce((sum, s) => (excluded.has(s.id) ? sum : sum + s.count), 0),
    searchable: () => sources.filter((s) => s.canSearch && !excluded.has(s.id)).map((s) => s.id),
    beforeReplace: () => masonry.current?.snapshot(),
  });
  const wallIndex = useMemo(() => new Map(wall.shots.map((s, i) => [s.id, i])), [wall.shots]);
  const broken = useFailed();
  useEffect(clearFailure, [query, scope, live]);

  const [density, setDensity] = useState(loadDensity);
  const columnWidth = columnWidths[density];

  const [picked, setPicked] = useState<readonly ShotView[]>([]);
  const pickedIds = useMemo(() => new Set(picked.map((s) => s.id)), [picked]);
  const [editing, setEditing] = useState<string>();
  const noteReturn = useRef<Element | null>(null);

  const [opened, setOpened] = useState<Opened>();
  // 閉じる動きが終わるまで、選択の列は焦点表示の中に描く。外の列はその後に描き、2 本を重ねない
  const [lightboxMounted, setLightboxMounted] = useState(false);
  const returnFocus = useRef<() => void>(undefined);
  const afterClose = useRef<() => void>(undefined);
  const [dragging, setDragging] = useState(false);

  // 選択の列が一度見えた後に描き直すとき（焦点表示との受け渡し）は、入場の動きを付けない
  const hasPicks = picked.length > 0;
  const [trayShown, setTrayShown] = useState(false);
  useEffect(() => setTrayShown(hasPicks), [hasPicks]);

  useEffect(() => {
    getSelection().then(setPicked);
  }, []);

  useLayoutEffect(() => {
    if (wall.generation > 0) window.scrollTo({ top: 0 });
  }, [wall.generation]);

  /** 壁にある Shot は壁の最新の値で、壁から外れた Shot は開いた時点の値で見せる */
  const fromWall = (shot: ShotView) => {
    const index = wallIndex.get(shot.id);
    return index === undefined ? shot : wall.shots[index];
  };
  const lightboxShot = !opened
    ? undefined
    : opened.list === "wall"
      ? fromWall(opened.shot)
      : opened.list[opened.index];
  const lightboxFrom = opened?.from;
  const lightbox = useMemo<LightboxTarget | undefined>(
    () => (lightboxShot ? { shot: lightboxShot, from: lightboxFrom } : undefined),
    [lightboxShot, lightboxFrom],
  );

  const openLightbox = (next: Opened) => {
    setOpened(next);
    setLightboxMounted(true);
  };

  useLayoutEffect(() => {
    if (lightboxMounted) return;
    afterClose.current?.();
    afterClose.current = undefined;
  }, [lightboxMounted]);

  const navigate = (next: typeof history) => {
    window.clearTimeout(typing.current);
    setHistory(next);
    setText(current(next).text);
  };

  const onText = (value: string) => {
    setText(value);
    window.clearTimeout(typing.current);
    typing.current = window.setTimeout(() => setHistory((h) => edit(h, value)), SEARCH_DEBOUNCE_MS);
  };

  const focusSearch = () => {
    input.current?.focus();
    input.current?.select();
  };

  /** 壁のタイルへ焦点を戻す。壁から外れていたら検索欄へ */
  const focusTile = (id: string) => {
    if (!masonry.current?.focus(id)) focusSearch();
  };

  const closeLightbox = (then?: () => void) => {
    const id = lightboxShot?.id;
    afterClose.current =
      then ?? (opened?.list === "wall" && id ? () => focusTile(id) : returnFocus.current);
    setOpened(undefined);
  };

  const seedWith = (seed: NonNullable<Query["seed"]>) => {
    navigate(push(history, { text: "", seed }));
    if (opened) closeLightbox(focusSearch);
    else focusSearch();
  };

  const seedImage = (image: Blob) =>
    seedWith({ type: "image", image, preview: URL.createObjectURL(image) });

  const toggle = async (shot: ShotView) => {
    const on = !pickedIds.has(shot.id);
    const updated = await setSelection(shot.id, { selected: on });
    setPicked((list) =>
      on
        ? [...list.filter((s) => s.id !== shot.id), updated]
        : list.filter((s) => s.id !== shot.id),
    );
  };

  const toggleShot = useStableCallback((shot: ShotView) => void toggle(shot));

  // 選んだ Shot をドラッグしたときは、選んだものをまとめて渡す
  const dragShot = useStableCallback((shot: ShotView, event: DragEvent) =>
    dragOut(event, pickedIds.has(shot.id) ? picked : [shot]),
  );

  const startNote = async (shot: ShotView) => {
    noteReturn.current = document.activeElement;
    if (!pickedIds.has(shot.id)) await toggle(shot);
    setEditing(shot.id);
  };

  const endNote = async (id: string, note: string | undefined) => {
    setEditing(undefined);
    const returnTo = noteReturn.current;
    if (returnTo instanceof HTMLElement && returnTo.isConnected) returnTo.focus();
    const before = picked.find((s) => s.id === id)?.note ?? "";
    if (note === undefined || note.trim() === before) return;
    const updated = await setSelection(id, { selected: true, note: note.trim() || undefined });
    setPicked((list) => list.map((s) => (s.id === id ? updated : s)));
  };

  const openFromWall = useStableCallback((shot: ShotView, from: DOMRect) => {
    setHistory(commit);
    openLightbox({ list: "wall", shot, from });
  });

  const openFromTray = (shot: ShotView, from: DOMRect) => {
    // 焦点表示の間は列を Popup の中に描き直すので、閉じた後に描かれた列のサムネイルを引き直す
    returnFocus.current = () =>
      document
        .querySelector<HTMLElement>(`aside [data-shot-id="${CSS.escape(shot.id)}"] button`)
        ?.focus();
    openLightbox({ list: picked, index: picked.indexOf(shot), from });
  };

  const openSimilar = (shots: readonly ShotView[], index: number, from: DOMRect) => {
    if (opened?.list === "wall" && lightboxShot) {
      const id = lightboxShot.id;
      returnFocus.current = () => focusTile(id);
    }
    openLightbox({ list: shots, index, from });
  };

  const onSource = (source: SourceStatus, solo: boolean) => {
    if (source.login === "signedOut") {
      void login(source.id).then(refreshSources);
      return;
    }
    const ids = sources.map((s) => s.id);
    setExcluded((prev) => {
      if (solo) {
        const alone = prev.size === ids.length - 1 && !prev.has(source.id);
        return alone ? new Set() : new Set(ids.filter((id) => id !== source.id));
      }
      const next = new Set(prev);
      if (!next.delete(source.id)) next.add(source.id);
      // 全部を外すと壁が空になるだけなので、最後の 1 つを外したら全部入りへ戻す
      return next.size === ids.length ? new Set() : next;
    });
  };

  /** 操作を行う。既定の動作に任せるときは false を返す */
  const perform = (command: Command): boolean => {
    const shot = shotAt(document.activeElement) ?? lightboxShot;
    switch (command.type) {
      case "focusSearch":
        focusSearch();
        return true;
      case "type": {
        // 焦点だけを検索欄へ移し、字の挿入はブラウザに任せる。IME の打鍵も 1 打目から検索欄で組み立てられる
        const field = input.current;
        if (!field) return false;
        field.focus();
        field.setSelectionRange(field.value.length, field.value.length);
        return false;
      }
      case "back":
        navigate(back(history));
        return true;
      case "forward":
        navigate(forward(history));
        return true;
      case "density": {
        const next = stepDensity(density, command.step);
        setDensity(next);
        saveDensity(next);
        return true;
      }
      case "toWall": {
        const first = wall.shots[0];
        if (!first) return false;
        setHistory(commit);
        masonry.current?.focus(first.id);
        return true;
      }
      case "live": {
        if (text.trim() === "") return true;
        window.clearTimeout(typing.current);
        const next = commit(edit(history, text));
        setHistory(next);
        setLiveRun({ query: current(next) });
        return true;
      }
      case "unseed":
        if (!query.seed) return false;
        navigate(push(history, { text: "" }));
        return true;
      case "step": {
        if (!opened) return false;
        if (opened.list !== "wall") {
          const index = Math.min(opened.list.length - 1, Math.max(0, opened.index + command.delta));
          setOpened({ ...opened, index, from: undefined });
          return true;
        }
        // 壁から外れた Shot では前後をたどれない
        const at = wallIndex.get(opened.shot.id);
        if (at === undefined) return true;
        const next = wall.shots[Math.min(wall.shots.length - 1, Math.max(0, at + command.delta))];
        setOpened({ list: "wall", shot: next });
        return true;
      }
      case "seed":
        if (!shot) return false;
        seedWith({ type: "shot", shot });
        return true;
      case "select":
        if (!shot) return false;
        void toggle(shot);
        return true;
      case "note":
        if (!shot) return false;
        void startNote(shot);
        return true;
      case "openUrl": {
        const url = command.origin ? shot?.origin : shot?.url;
        if (!url) return false;
        void openInBrowser(url);
        return true;
      }
      case "copyImage":
        if (!shot) return false;
        void copyShot(shot);
        return true;
      case "copySelection":
        if (picked.length === 0) return false;
        void copySelection(picked);
        return true;
      case "shuffle":
        return shuffle();
    }
  };

  const focusArea = (): FocusArea => {
    const active = document.activeElement;
    if (active === input.current) return "search";
    if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) return "field";
    return shotAt(active) ? "tile" : "other";
  };

  useEffect(() => {
    // アプリのホットキー。焦点表示の外の検索欄へ移るので、開いていれば閉じてから移る
    const summon = () => (opened ? closeLightbox(focusSearch) : focusSearch());
    const onKeyDown = (event: KeyboardEvent) => {
      const command = keyCommand(event, {
        focus: focusArea(),
        lightbox: opened !== undefined,
        searchEmpty: text === "",
      });
      if (command && perform(command)) event.preventDefault();
    };
    const onPaste = (event: ClipboardEvent) => {
      const image = imageIn(event.clipboardData);
      if (!image) return;
      event.preventDefault();
      seedImage(image);
    };
    const hasFiles = (event: DragEvent) =>
      !draggingOut() && (event.dataTransfer?.types.includes("Files") ?? false);
    const onDragOver = (event: DragEvent) => {
      if (!hasFiles(event)) return;
      event.preventDefault();
      setDragging(true);
    };
    const onDragLeave = (event: DragEvent) => {
      if (event.relatedTarget === null) setDragging(false);
    };
    const onDrop = (event: DragEvent) => {
      if (!hasFiles(event)) return;
      event.preventDefault();
      setDragging(false);
      const image = imageIn(event.dataTransfer);
      if (image) seedImage(image);
    };
    // 焦点表示の Popup は矢印キーの伝播を止めるので、捕捉の段階で受ける
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("paste", onPaste);
    window.addEventListener("dragover", onDragOver);
    window.addEventListener("dragleave", onDragLeave);
    window.addEventListener("drop", onDrop);
    window.addEventListener("mitate:focus-search", summon);
    return () => {
      window.removeEventListener("keydown", onKeyDown, true);
      window.removeEventListener("paste", onPaste);
      window.removeEventListener("dragover", onDragOver);
      window.removeEventListener("dragleave", onDragLeave);
      window.removeEventListener("drop", onDrop);
      window.removeEventListener("mitate:focus-search", summon);
    };
  });

  const busy = useMemo(() => {
    const ids = new Set(wall.pending);
    for (const source of sources) if (source.sync.state === "syncing") ids.add(source.id);
    return ids;
  }, [wall.pending, sources]);

  const tray = hasPicks ? (
    <Tray
      shots={picked}
      sources={sourceMap}
      editing={editing}
      handoff={trayShown}
      onEditEnd={(id, note) => void endNote(id, note)}
      onOpen={openFromTray}
      onToggle={toggleShot}
      onCopy={() => copySelection(picked)}
      onClear={() => {
        void clearSelection().then(() => setPicked([]));
      }}
    />
  ) : null;

  const searching = wall.loading && wall.pending.size === 0;
  const empty = !wall.loading && wall.pending.size === 0 && wall.shots.length === 0;

  return (
    <div className={styles.app}>
      <Header
        inputRef={input}
        text={text}
        seed={query.seed}
        onText={onText}
        onUnseed={() => navigate(push(history, { text: "" }))}
        searching={searching}
        broken={broken}
        sources={sources}
        excluded={excluded}
        busy={busy}
        failed={wall.failed}
        onSource={onSource}
      />
      <main className={styles.main({ tray: hasPicks })}>
        <ShotWall
          ref={masonry}
          shots={wall.shots}
          generation={wall.generation}
          columnWidth={columnWidth}
          sources={sourceMap}
          selected={pickedIds}
          fresh={wall.fresh}
          stale={wall.loading}
          onNearEnd={loadMore}
          onExitTop={focusSearch}
          onOpen={openFromWall}
          onToggle={toggleShot}
          onDragOut={dragShot}
        />
        {empty ? (
          <div className={styles.empty} role="img" aria-label="一致するものが無い">
            <Icon name="photo-off" size="xl" />
          </div>
        ) : null}
      </main>
      {lightboxMounted ? null : tray}
      <Lightbox
        target={lightbox}
        scope={scope}
        columnWidth={columnWidth}
        sources={sourceMap}
        selected={pickedIds}
        tray={tray}
        trayShown={hasPicks}
        onClose={() => closeLightbox()}
        onClosed={() => {
          // 閉じ終える前に開き直したときは、列を外へ戻さない
          if (!opened) setLightboxMounted(false);
        }}
        onOpenSimilar={openSimilar}
        onToggle={toggleShot}
        onDragOut={dragShot}
      />
      {dragging ? <div className={styles.drop} /> : null}
    </div>
  );
}
