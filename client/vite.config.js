import { defineConfig } from "vite";

export default defineConfig({
  server: { port: 5190, fs: { allow: [".."] } },
});
