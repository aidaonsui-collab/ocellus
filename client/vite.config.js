import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

// Two pages share src/engine.js: the chain verifier (/) and the WebGL demo (/demo/).
export default defineConfig({
  server: { port: 5190, fs: { allow: [".."] } },
  build: {
    rollupOptions: {
      input: {
        main: fileURLToPath(new URL("index.html", import.meta.url)),
        demo: fileURLToPath(new URL("demo/index.html", import.meta.url)),
      },
    },
  },
});
