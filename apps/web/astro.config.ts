import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "astro/config";

// A static site: plain HTML and CSS, no JavaScript sent to the browser.
export default defineConfig({
  site: "https://whisper.0xhoney.com",
  // The stylesheet stays a file of its own, so the page needs no inline styles
  // and the Content-Security-Policy in public/_headers can allow "self" only.
  build: { inlineStylesheets: "never" },
  devToolbar: { enabled: false },
  server: { host: "127.0.0.1" },
  vite: { plugins: [tailwindcss()] },
});
