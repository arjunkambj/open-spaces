#!/usr/bin/env node
// finish: the last step of `pnpm build`, after Vite has prerendered the pages into dist/client.
//
// The prerendered pages carry a few small inline scripts from TanStack Start: the data the
// page starts from, and a line that tidies up after it. They are the same on every visit, so
// instead of allowing any inline script ('unsafe-inline'), the Content-Security-Policy in
// _headers allows exactly these, by their SHA-256 hash. This step writes those hashes in.
// It stops the build if a page is missing or if a page loads a script from another site.

import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";

const out = new URL("../dist/client/", import.meta.url);
const pages = ["index.html", "404.html"];
const placeholder = "'inline-scripts'";

const hashes = new Set();
for (const page of pages) {
  const html = await readFile(new URL(page, out), "utf8");
  for (const [, attributes, body] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)) {
    const src = /\ssrc="([^"]*)"/.exec(attributes)?.[1];
    if (src !== undefined) {
      if (!src.startsWith("/")) throw new Error(`${page} loads a script from another site: ${src}`);
      continue;
    }
    hashes.add(`'sha256-${createHash("sha256").update(body, "utf8").digest("base64")}'`);
  }
}

const headersFile = new URL("_headers", out);
const headers = await readFile(headersFile, "utf8");
if (!headers.includes(placeholder)) throw new Error(`_headers has no ${placeholder} to fill in`);
await writeFile(headersFile, headers.replace(placeholder, [...hashes].join(" ")));
console.log(`finish: ${pages.length} pages, ${hashes.size} inline scripts allowed by hash`);
