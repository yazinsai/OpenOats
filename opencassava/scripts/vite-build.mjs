import { build } from "vite";
import react from "@vitejs/plugin-react";
import "./sync-version.mjs";

await build({
  configFile: false,
  plugins: [react()],
});
