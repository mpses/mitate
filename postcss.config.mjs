import { join } from "node:path";

import pandacss from "@pandacss/dev/postcss";

const here = import.meta.dirname;

export default {
  plugins: [pandacss({ cwd: here, configPath: join(here, "panda.config.ts") })],
};
