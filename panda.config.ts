import { bakutanPreset } from "@bakutan-org/ui/panda-preset";
import { defineConfig } from "@pandacss/dev";

export default defineConfig({
  presets: ["@pandacss/dev/presets", bakutanPreset],
  include: ["./web/src/**/*.{ts,tsx}"],
  exclude: [],
  outdir: "styled-system",
  importMap: "@bakutan-org/ui/styled-system",
  hash: false,
});
