import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { getCurrentWindow } from "@tauri-apps/api/window";
import "./App.css";
import App from "./App.tsx";
import { OverlayApp } from "./OverlayApp.tsx";

async function bootstrap() {
  const label = getCurrentWindow().label;
  const Root = label === "overlay" ? OverlayApp : App;

  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <Root />
    </StrictMode>
  );
}

bootstrap();
