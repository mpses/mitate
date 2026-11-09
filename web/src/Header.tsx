import { useEffect, useId, useState, type Ref } from "react";

import {
  ActiveIndicator,
  Icon,
  IconButton,
  ProgressiveBlur,
  Spinner,
  Tooltip,
} from "@bakutan-org/ui";
import { css } from "@bakutan-org/ui/styled-system/css";

import type { SourceStatus } from "./api";
import type { Seed } from "./history";
import { SourceIcon } from "./SourceIcon";
import { stillOf } from "./Tile";

export interface HeaderProps {
  inputRef: Ref<HTMLInputElement>;
  text: string;
  seed: Seed | undefined;
  onText: (text: string) => void;
  onUnseed: () => void;
  /** 壁に出す結果を待っている。live の問い合わせはサイトのアイコンの輪で示すので含めない */
  searching: boolean;
  /** API か画面の処理が失敗した */
  broken: boolean;
  sources: readonly SourceStatus[];
  excluded: ReadonlySet<string>;
  /** 同期中か live の問い合わせ中のサイト */
  busy: ReadonlySet<string>;
  failed: ReadonlySet<string>;
  /** solo は ⌥+クリック。そのサイトだけにする */
  onSource: (source: SourceStatus, solo: boolean) => void;
}

const styles = {
  // 上端 28px は窓のドラッグ領域。高さ 80px は ProgressiveBlur の高さに合わせる
  header: css({
    h: "80px",
    insetBlockStart: "0",
    position: "sticky",
    pt: "28px",
    px: "4",
    zIndex: 10,
  }),
  // 検索欄とアイコンの行の後ろでは下のメディアをほぼ隠し、下端だけ透かして壁へつなぐ。
  // 止まっているときは 1 行目のタイルを薄くしないよう早めに透かし、スクロール中は欄の下端まで隠す
  veil: css({
    bgGradient: "to-b",
    gradientFrom: "bg.default",
    gradientVia: "bg.default/85",
    gradientViaPosition: "65%",
    gradientTo: "bg.default/0",
    inset: "0",
    pointerEvents: "none",
    position: "absolute",
    "[data-scrolled] > &": { gradientViaPosition: "90%" },
  }),
  row: css({
    alignItems: "center",
    display: "flex",
    gap: "4",
    h: "full",
    position: "relative",
  }),
  field: css({
    alignItems: "center",
    bg: "bg.subtle",
    borderRadius: "full",
    color: "text.subtle",
    display: "flex",
    flex: "1",
    gap: "2",
    h: "36px",
    maxW: "lg",
    minW: "0",
    px: "3",
    _focusWithin: { outline: "2px solid", outlineColor: "focus.default", outlineOffset: "2px" },
  }),
  // 虫眼鏡の位置に、待っている間は Spinner、失敗したら右上に点を出す
  lead: css({ display: "inline-flex", flexShrink: 0, position: "relative" }),
  leadMark: css({ insetBlockStart: "-0.5", insetInlineEnd: "-0.5", position: "absolute" }),
  input: css({
    bg: "transparent",
    border: "none",
    color: "text.strong",
    flex: "1",
    h: "full",
    minW: "0",
    outline: "none",
    p: "0",
    textStyle: "type.base.normal",
  }),
  seed: css({
    alignItems: "center",
    display: "flex",
    flexShrink: 0,
    gap: "0-5",
  }),
  seedImage: css({
    borderRadius: "xs",
    display: "block",
    h: "24px",
    maxW: "48px",
    minW: "18px",
    objectFit: "cover",
  }),
  sources: css({
    alignItems: "center",
    display: "flex",
    flexShrink: 0,
    gap: "1",
    listStyle: "none",
    m: "0",
    ml: "auto",
    p: "0",
  }),
};

function SeedChip({
  seed,
  sources,
  onUnseed,
}: {
  seed: Seed;
  sources: readonly SourceStatus[];
  onUnseed: () => void;
}) {
  const preview = seed.type === "image" ? seed.preview : stillOf(seed.shot);
  return (
    <span className={styles.seed}>
      {preview && !(seed.type === "shot" && seed.shot.kind === "text") ? (
        <img alt="" className={styles.seedImage} draggable={false} src={preview} />
      ) : seed.type === "shot" ? (
        <SourceIcon
          id={seed.shot.source}
          source={sources.find((source) => source.id === seed.shot.source)}
        />
      ) : null}
      <IconButton aria-label="種を外す" variant="ghost" size="small" onClick={onUnseed}>
        <Icon name="x" size="xs" />
      </IconButton>
    </span>
  );
}

function sourceLabel(source: SourceStatus) {
  return `${source.name} ${source.count.toLocaleString()}`;
}

/** 読み上げ名。画面には出さない状態（ログイン、同期、失敗）を名前に含める */
function sourceName(source: SourceStatus, busy: boolean, failed: boolean) {
  if (source.login === "signedOut") return `${source.name} にログイン`;
  return `${source.name}${busy ? "（同期中）" : ""}${failed ? "（問い合わせに失敗）" : ""}`;
}

/** 窓が少しでもスクロールしているか */
function useScrolled() {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const update = () => setScrolled(window.scrollY > 0);
    update();
    window.addEventListener("scroll", update, { passive: true });
    return () => window.removeEventListener("scroll", update);
  }, []);
  return scrolled;
}

/** 検索欄とサイトのアイコン列。スクロールしても上端に残る */
export function Header({
  inputRef,
  text,
  seed,
  onText,
  onUnseed,
  searching,
  broken,
  sources,
  excluded,
  busy,
  failed,
  onSource,
}: HeaderProps) {
  const scrolled = useScrolled();
  const brokenId = useId();
  return (
    <header className={styles.header} data-scrolled={scrolled ? "" : undefined}>
      <ProgressiveBlur side="top" />
      <div className={styles.veil} />
      <div className={styles.row}>
        <form role="search" className={styles.field} onSubmit={(event) => event.preventDefault()}>
          <span className={styles.lead}>
            {searching ? (
              <Spinner size="sm" aria-label="検索中" />
            ) : (
              <Icon name="search" size="sm" />
            )}
            {broken ? <ActiveIndicator className={styles.leadMark} tone="error" /> : null}
          </span>
          {seed ? <SeedChip seed={seed} sources={sources} onUnseed={onUnseed} /> : null}
          <input
            ref={inputRef}
            aria-label="検索"
            aria-describedby={broken ? brokenId : undefined}
            autoComplete="off"
            autoFocus
            className={styles.input}
            enterKeyHint="search"
            spellCheck={false}
            type="text"
            value={text}
            onChange={(event) => onText(event.currentTarget.value)}
          />
          {broken ? (
            <span id={brokenId} hidden>
              問い合わせに失敗した
            </span>
          ) : null}
        </form>
        <ul className={styles.sources}>
          {sources.map((source) => {
            const off = excluded.has(source.id);
            const signedOut = source.login === "signedOut";
            const sourceBusy = busy.has(source.id);
            const sourceFailed = failed.has(source.id);
            return (
              <li key={source.id}>
                <Tooltip label={sourceLabel(source)} placement="bottom">
                  <IconButton
                    variant="ghost"
                    size="large"
                    aria-label={sourceName(source, sourceBusy, sourceFailed)}
                    aria-pressed={signedOut ? undefined : !off}
                    onClick={(event) => onSource(source, event.altKey)}
                  >
                    <SourceIcon
                      id={source.id}
                      source={source}
                      busy={sourceBusy}
                      dim={off || signedOut}
                      dot={sourceFailed ? "error" : signedOut ? "signedOut" : undefined}
                    />
                  </IconButton>
                </Tooltip>
              </li>
            );
          })}
        </ul>
      </div>
    </header>
  );
}
