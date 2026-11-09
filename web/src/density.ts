/** 壁の列の最小幅（px）。⌘= で 1 段広く（列が減る）、⌘- で 1 段狭く（列が増える） */
export const columnWidths = [140, 180, 220, 280, 360, 460] as const;

const defaultDensity = 2;
const storageKey = "mitate:density";

export function loadDensity(): number {
  try {
    const saved = localStorage.getItem(storageKey);
    const density = saved === null ? defaultDensity : Number(saved);
    return Number.isInteger(density) && density >= 0 && density < columnWidths.length
      ? density
      : defaultDensity;
  } catch {
    // 保存先を読めない窓では既定の密度で始める
    return defaultDensity;
  }
}

export function saveDensity(density: number): void {
  try {
    localStorage.setItem(storageKey, String(density));
  } catch {
    // 保存できない窓では、開いている間だけ効かせる
  }
}

export function stepDensity(density: number, step: -1 | 0 | 1): number {
  if (step === 0) return defaultDensity;
  return Math.min(columnWidths.length - 1, Math.max(0, density + step));
}
