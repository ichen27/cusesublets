// Builds the Tour Studio viewer page (studio.html) into studio-dist/ for studio/server.py.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
  plugins: [react()],
  publicDir: false,
  build: { outDir: "studio-dist", emptyOutDir: true, rollupOptions: { input: "studio.html" } },
});
