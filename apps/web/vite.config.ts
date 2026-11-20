import tailwindcss from "@tailwindcss/vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import viteReact from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { artwork } from "./artwork.ts";
import { latestRelease } from "./src/release.ts";

// One page, prerendered to plain HTML at build time and served as static files.
// The version next to the Download button is looked up here, once, and written into the page.
export default defineConfig(async () => {
  const { version } = await latestRelease();
  return {
    define: { __SPACES_VERSION__: JSON.stringify(version) },
    plugins: [
      tanstackStart({
        prerender: { enabled: true, crawlLinks: false, autoSubfolderIndex: false, failOnError: true },
        // The page, and the page for an address that does not exist (served with status 404).
        pages: [
          { path: "/", prerender: { enabled: true, outputPath: "/index.html" } },
          { path: "/404", prerender: { enabled: true, outputPath: "/404.html" } },
        ],
      }),
      // React's plugin must come after Start's.
      viteReact(),
      tailwindcss(),
      artwork(),
    ],
  };
});
