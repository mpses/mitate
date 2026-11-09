import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

// ui の styles は design-tokens の fonts.css と Tabler Icons の webfont を含む
import "@bakutan-org/ui/globals";
import "@bakutan-org/ui/styles";
import "./index.css";

import { App } from "./App";
import { installDragOut } from "./drag";
import { installFailureReporting } from "./failure";

installFailureReporting();
installDragOut();

const root = document.getElementById("root");
if (!root) throw new Error("#root が無い");

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
