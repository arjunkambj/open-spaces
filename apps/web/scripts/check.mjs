#!/usr/bin/env node
// check: look at a running copy of the site the way a visitor's browser would.
//
//   node scripts/check.mjs [address]      default: https://whisper.0xhoney.com
//
// It asks for the page, then for every file and link the page names, and stops with an
// error when something is missing: a broken link, a file from another site, a script the
// Content-Security-Policy does not allow, a response header we promise, the version next to
// the Download button, the 404 page.
// The deploy workflow runs it after each deploy. `pnpm preview` gives a local copy to try
// it on: node scripts/check.mjs http://127.0.0.1:8788

import { createHash } from "node:crypto";

const live = "https://whisper.0xhoney.com";
const base = (process.argv[2] ?? live).replace(/\/$/, "");
const problems = [];
const fail = (message) => problems.push(message);

/** Ask for an address and throw the body away. Redirects are followed. */
async function ask(address, method = "GET") {
  const response = await fetch(address, { method, signal: AbortSignal.timeout(30_000) });
  await response.body?.cancel();
  return response;
}

// Asked for the way a browser asks: that is when Cloudflare would add its analytics script.
const page = await fetch(`${base}/`, { headers: { Accept: "text/html" }, signal: AbortSignal.timeout(30_000) });
const html = await page.text();
if (page.status !== 200) fail(`the page answered ${page.status}`);

// --- Headers -----------------------------------------------------------------------------

const wanted = {
  "content-security-policy": /default-src 'none'.*script-src 'self'/,
  "strict-transport-security": /max-age=\d+/,
  "x-content-type-options": /nosniff/,
  "referrer-policy": /no-referrer/,
  "permissions-policy": /microphone=\(\)/,
  "cache-control": /max-age=0.*no-transform/,
};
for (const [name, pattern] of Object.entries(wanted)) {
  const value = page.headers.get(name) ?? "";
  if (!pattern.test(value)) fail(`header ${name} is "${value}"`);
}
if (page.headers.has("set-cookie")) fail("the page sets a cookie");

// Scripts may come from this site, or be one of the inline scripts the policy names by hash.
const scriptSrc = /script-src([^;]*)/.exec(page.headers.get("content-security-policy") ?? "")?.[1] ?? "";
for (const source of scriptSrc.trim().split(/\s+/).filter(Boolean)) {
  if (source !== "'self'" && !/^'sha256-[A-Za-z0-9+/=]+'$/.test(source)) {
    fail(`the Content-Security-Policy allows scripts from ${source}`);
  }
}

// --- What the page says ------------------------------------------------------------------

const version = /Version (\d+\.\d+\.\d+[^\s<]*)/.exec(html)?.[1];
if (!version) fail("the page does not show a version");
if (!html.includes("Where your words go")) fail("the prerendered page does not hold the page's text");
if (!html.includes('href="https://github.com/arjunkambj/open-spaces/releases/latest/download/Spaces.dmg"')) {
  fail("the prerendered page has no Download link");
}
for (const [, attributes, body] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
  const src = /\ssrc="([^"]*)"/.exec(attributes)?.[1];
  if (src !== undefined) {
    if (!src.startsWith("/")) fail(`the page loads a script from another site: ${src} (was one added on the way?)`);
    continue;
  }
  const hash = `'sha256-${createHash("sha256").update(body, "utf8").digest("base64")}'`;
  if (!scriptSrc.includes(hash)) fail(`the page holds an inline script the policy does not allow: ${body.slice(0, 60)}`);
}

// --- Every address the page names --------------------------------------------------------

const named = new Set();
for (const [, attribute, value] of html.matchAll(/\s(href|src|srcset|content)="([^"]*)"/g)) {
  const parts = attribute === "srcset" ? value.split(",").map((part) => part.trim().split(/\s+/)[0]) : [value];
  for (const part of parts) {
    if (attribute === "content" && !/^https?:\/\//.test(part)) continue;
    if (part) named.add(part.replaceAll("&amp;", "&"));
  }
}

const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map(([, id]) => id));
const own = [];
const outside = [];
for (const address of named) {
  if (address.startsWith("#")) {
    if (!ids.has(address.slice(1))) fail(`nothing on the page is called ${address}`);
  } else if (address.startsWith("/")) {
    own.push(base + address);
  } else if (address.startsWith(live)) {
    own.push(base + address.slice(live.length));
  } else if (new URL(address).hostname === "github.com") {
    outside.push(address);
  } else {
    fail(`the page names another site: ${address}`);
  }
}

for (const address of [...own, `${base}/robots.txt`, `${base}/sitemap.xml`, `${base}/favicon.ico`]) {
  const response = await ask(address);
  if (response.status !== 200) fail(`${address} answered ${response.status}`);
  const fingerprinted = new URL(address).pathname.startsWith("/assets/");
  if (fingerprinted && !/immutable/.test(response.headers.get("cache-control") ?? "")) {
    fail(`${address} is not kept by browsers (cache-control: ${response.headers.get("cache-control")})`);
  }
}
for (const address of outside) {
  // HEAD, so the download is checked without fetching the whole disk image.
  const response = await ask(address, "HEAD");
  if (response.status !== 200) fail(`${address} answered ${response.status}`);
}

const missing = await fetch(`${base}/no-such-page`, { signal: AbortSignal.timeout(30_000) });
if (missing.status !== 404) fail(`an address that does not exist answered ${missing.status}, not 404`);
if (!(await missing.text()).includes("Page not found")) fail("the 404 page is not ours");

// --- The verdict -------------------------------------------------------------------------

console.log(`${base}: version ${version ?? "?"}, ${own.length} files of its own, ${outside.length} links to GitHub`);
if (problems.length > 0) {
  for (const problem of problems) console.error(`  x ${problem}`);
  process.exit(1);
}
console.log("  all in order");
