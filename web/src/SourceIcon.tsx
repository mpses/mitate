import { ActiveIndicator, Avatar } from "@bakutan-org/ui";
import { css, cva } from "@bakutan-org/ui/styled-system/css";

import type { SourceStatus } from "./api";

export interface SourceIconProps {
  /** source id。一覧に無いサイト（sources に載っていない検索先）でも頭文字で描く */
  id: string;
  source: SourceStatus | undefined;
  /** 同期中か live の問い合わせ中。アイコンの周りに輪を回す */
  busy?: boolean;
  /** 右上の点。signedOut はログインを、error は問い合わせの失敗を示す */
  dot?: "signedOut" | "error";
  dim?: boolean;
}

const styles = {
  root: css({ display: "inline-flex", flexShrink: 0, position: "relative" }),
  // 点は薄くせずに読ませるので、薄くするのはアイコンと輪だけ
  face: cva({
    base: {
      display: "inline-flex",
      position: "relative",
      transitionDuration: "fast",
      transitionProperty: "opacity, filter",
      transitionTimingFunction: "out",
    },
    variants: {
      dim: {
        true: { filter: "grayscale(1)", opacity: 0.35 },
        false: {},
      },
    },
  }),
  // 24px のアイコンの外側 2px に、上の 4 分の 1 だけ色を付けた輪を回す。
  // IconButton は中の svg を icon の寸法にそろえるので、輪は svg で描かない
  ring: css({
    animationDuration: "loop",
    animationIterationCount: "infinite",
    animationName: "spin",
    animationTimingFunction: "linear",
    borderBlockStartColor: "spinner.indicator",
    borderColor: "transparent",
    borderRadius: "full",
    borderStyle: "solid",
    borderWidth: "semibold",
    inset: "-0.5",
    pointerEvents: "none",
    position: "absolute",
    _motionReduce: {
      animationDuration: "pulse",
      animationName: "pulse",
      animationTimingFunction: "ease",
    },
  }),
  // 点の中心を円の右上 45° の縁に寄せる
  dot: css({ insetBlockStart: "0", insetInlineEnd: "0", position: "absolute" }),
};

/** サイトの favicon。無ければ頭文字の円 */
export function SourceIcon({ id, source, busy = false, dot, dim = false }: SourceIconProps) {
  const name = source?.name ?? id;
  return (
    <span className={styles.root}>
      <span className={styles.face({ dim })}>
        <Avatar aria-hidden size="xs" src={source?.icon} initials={[...name][0]?.toUpperCase()} />
        {busy ? <span aria-hidden className={styles.ring} /> : null}
      </span>
      {dot ? (
        <ActiveIndicator className={styles.dot} tone={dot === "error" ? "error" : "warning"} />
      ) : null}
    </span>
  );
}
