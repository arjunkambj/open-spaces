# The Spaces website

One page that says what Spaces is and lets people download it: <https://whisper.0xhoney.com>.

It is built with [TanStack Start](https://tanstack.com/start) (React) and [Tailwind CSS](https://tailwindcss.com), and **prerendered**: while the site is built, the page is rendered once to plain HTML. Cloudflare serves those files as they are ([Workers static assets](https://developers.cloudflare.com/workers/static-assets/)); no code of ours runs when someone visits.

The HTML holds the whole page, so it reads in full and the Download button works before any script runs, or without scripts. Then a small React bundle from this site takes over the page ("hydration"). It adds one thing: the Copy button next to the agent command. There are no analytics and no cookies, and nothing is loaded from other sites: the scripts, the styles, the typeface and the pictures all come from this site. The only links that leave the page go to GitHub.

## Run it

You need Node.js 22 or newer and pnpm. From the repository root:

```bash
pnpm install        # once
pnpm web            # the page at http://127.0.0.1:4321, updating as you edit
pnpm web:build      # the finished site, in apps/web/dist/client
```

To see the finished site the way Cloudflare serves it, with the real response headers and the 404 page:

```bash
pnpm web:build
pnpm --filter @open-spaces/web run preview       # http://127.0.0.1:8788
```

Two checks:

```bash
pnpm --filter @open-spaces/web run lint          # the types, in every file (tsc --noEmit)
pnpm --filter @open-spaces/web run check:site    # the live site: links, files, headers, version
```

`check:site` takes another address too, such as the preview: `pnpm --filter @open-spaces/web run check:site http://127.0.0.1:8788`.

## Change the words

Every word on the page is in one file: [`src/content.ts`](src/content.ts). Edit the text there and run `pnpm web` to see it.

The page has one idea: what you say, and what lands. The top shows a spoken line in monospace, with the "um" and "uh" struck out, and the clean sentence it becomes, set large in a book serif. That sentence is also a row in the Home picture below it, so keep the two the same. Words that people say are set in monospace; words Spaces writes, and the headings, are set in the serif.

Keep it plain English: short sentences, everyday words. Say only what is true of the app as it ships. The root [README](../../README.md) is the reference for that.

The line for connecting an AI agent, and the tool names in the Agents section, are copied from [`docs/agents.md`](../../docs/agents.md). When they change there, change them here.

## Change the pictures

| Picture | File | Where it comes from |
| --- | --- | --- |
| The app window at the top | `src/images/home-light.png`, `home-dark.png` | The Mac app's own snapshot tool, screen `mac-hub-home` |
| The meeting | `src/images/meeting-light.png`, `meeting-dark.png` | The shared snapshot tool, screen `meeting-notes` |
| The app icon, the browser-tab icons | `../../assets/icon-1024.png` | The app's icon. Nothing to copy: the next build picks up a new one |
| The picture shown when the link is shared | made by `artwork.ts` | The icon, the window picture and two lines of text |
| The small pill with moving bars | `src/components/Pill.tsx` | Drawn with CSS |

To make fresh pictures of the app, with no window opened (see "Commands" in [AGENTS.md](../../AGENTS.md)):

```bash
"apps/macos/build/Spaces.app/Contents/MacOS/SpacesApp" --snapshots <folder>   # the Mac window
cd packages/ui && ../../scripts/swiftw run spaces-snapshots <folder>                # shared screens
```

Copy the light and the dark picture over the files above. Both must have the same size. All pictures show made-up sample data; keep it that way.

[`artwork.ts`](artwork.ts) is a small Vite plugin, using `sharp`, that makes each app picture in several widths as AVIF and WebP (the list is in [`src/pictures.ts`](src/pictures.ts)); the browser takes the one that fits, light or dark. It also makes `favicon.ico`, `icon.png`, `apple-touch-icon.png`, the icon in the header (`brand.png`) and the share picture (`og.png`). In `pnpm web` it makes each file the first time it is asked for; in `pnpm web:build` it adds them all to `dist/client`.

## The typeface

The headings and the typed sentence use [Newsreader](https://github.com/productiontype/Newsreader), under the SIL Open Font License. The file is `src/fonts/newsreader.woff2` (Latin letters, with its optical sizes, so it looks right both large and small); the build serves it from this site. The licence is served next to it, at `/fonts/newsreader-OFL.txt` ([`public/fonts/newsreader-OFL.txt`](public/fonts/newsreader-OFL.txt)). Everything else uses the system font.

## The version and the Download button

The button goes to

```
https://github.com/arjunkambj/open-spaces/releases/latest/download/Spaces.dmg
```

GitHub sends that address on to the newest release. The Release workflow attaches the disk image twice: as `Spaces-<version>.dmg` (the one installed apps update from) and as `Spaces.dmg`, so this address never changes.

The version next to the button is looked up **while the site is built** ([`src/release.ts`](src/release.ts), called once from [`vite.config.ts`](vite.config.ts)) and written into the HTML and the page's script alike. A visitor's browser asks GitHub nothing.

- The build asks GitHub where `releases/latest` leads. The answer ends in the tag, such as `v0.1.0`.
- If GitHub does not answer, it uses the version in `apps/macos/package.json`.

The page only changes when the site is built again. That is why a new release deploys the site (see below).

## How it gets to Cloudflare

The site is one Cloudflare Worker named `open-spaces-web`. It has no code: it only serves the files in `dist/client`. [`wrangler.jsonc`](wrangler.jsonc) describes it. (The build also leaves `dist/server`, the code that rendered the pages while building. It is not deployed.)

### How the page is built

`pnpm web:build` runs `vite build`, then `scripts/finish.mjs`.

- TanStack Start's Vite plugin builds the page's script and a server bundle, starts that bundle for a moment, and saves the HTML it renders for `/` as `dist/client/index.html` and for `/404` as `dist/client/404.html` (the `prerender` and `pages` settings in [`vite.config.ts`](vite.config.ts)).
- [`scripts/finish.mjs`](scripts/finish.mjs) reads those two pages. Each holds three small inline scripts from TanStack Start (the data the page starts from, and a line that removes it afterwards). It writes the SHA-256 hash of each into the Content-Security-Policy in `dist/client/_headers`, so exactly these may run and no other inline script can. It stops the build if a page loads a script from another site.

- **Address.** `whisper.0xhoney.com` is a "custom domain" of the Worker. Cloudflare makes the DNS record and the certificate by itself. The `*.workers.dev` address and the preview addresses are turned off, so there is one address.
- **Headers.** [`public/_headers`](public/_headers) sets them: a Content-Security-Policy that allows only the site's own files (scripts, styles, the typeface and pictures) plus the inline scripts named by hash, HSTS, and the usual hardening headers. It needs no `unsafe-inline`. Files under `/assets/` carry a fingerprint in their name and are kept by browsers for a year. The page itself is checked again on every visit.
- **Nothing is added on the way.** The `0xhoney.com` domain has Cloudflare Web Analytics switched on, which adds a tracking script to every page of the domain. Every file here is sent with `Cache-Control: no-transform`, which tells Cloudflare to leave it alone, and the Content-Security-Policy would refuse the script anyway. `check:site` fails if the page holds a script from another site, or an inline script the policy does not name. Do not remove `no-transform`.
- **Plain `http://`.** The site answers on `http://` as well as `https://`. Sending everyone to `https://` is a switch for the whole domain (Cloudflare dashboard: the domain > SSL/TLS > Edge Certificates > **Always Use HTTPS**), so it is left to the domain's owner. Browsers that have visited once use `https://` by themselves (HSTS).
- **404.** An address that does not exist gets `404.html` with status 404. In the browser, the router shows the same "Page not found" there.
- Also in `public`: `robots.txt` and `sitemap.xml`.

### Deploy from your Mac

```bash
pnpm web:deploy     # builds, then runs `wrangler deploy`
```

Wrangler (Cloudflare's command-line tool, installed with `pnpm install`) must be allowed into **the Cloudflare account that holds the `0xhoney.com` domain**. A Worker can only be given an address on a domain of its own account. No account ID is kept in this repository. Either:

- keep a token and the account ID in a private file outside the repository, and load it for the one command. The maintainer's Mac has `~/.config/open-spaces/cloudflare.env`, two lines (`CLOUDFLARE_API_TOKEN=...` and `CLOUDFLARE_ACCOUNT_ID=...`), readable only by its owner:

  ```bash
  (set -a; source ~/.config/open-spaces/cloudflare.env; pnpm web:deploy)
  ```

- or sign in once with `pnpm --filter @open-spaces/web exec wrangler login` (it opens a browser; choose that account). If the sign-in reaches more than one account, also set `CLOUDFLARE_ACCOUNT_ID`.

Then check the result: `pnpm --filter @open-spaces/web run check:site`.

### Deploy from GitHub

[`.github/workflows/web.yml`](../../.github/workflows/web.yml) builds the site on every pull request. It deploys:

- on a push to `main` that changes `apps/web`, the app icon, or the lock file;
- after every release, so the page shows the new version;
- when you start it by hand (Actions > Website > Run workflow).

It needs two repository secrets. Until they are set, the deploy job prints a notice and does nothing.

1. In the [Cloudflare dashboard](https://dash.cloudflare.com), switch to the account that holds `0xhoney.com`.
2. Go to **Manage account > Account API tokens > Create Token**, and choose **Custom** ("Start from scratch").
3. Give it two permission policies, and nothing else:
   - **Entire Account**: Workers Scripts, **Edit**
   - **Add policy**, then **Specified Domains** with only `0xhoney.com`: Workers Routes, **Edit**
4. Leave the expiry as you like, review, and create the token. Copy it: it is shown once. The same window shows the **Account ID**.
5. Save both in the repository:

   ```bash
   gh secret set CLOUDFLARE_API_TOKEN     # paste the token
   gh secret set CLOUDFLARE_ACCOUNT_ID    # paste the account ID
   ```

These two permissions are all a deploy needs. The token can change Workers in that account, so keep it only in GitHub's secrets or in a private file outside the repository, never in a file here. To take it back, delete it on the same dashboard page.

## Layout

```
vite.config.ts       TanStack Start, React, Tailwind; what is prerendered; the version
artwork.ts           the icons, the share picture and the app pictures, made at build time
wrangler.jsonc       the Cloudflare Worker and its address
public/              files served as they are: _headers, robots.txt, sitemap.xml, the font licence
scripts/finish.mjs   the last build step: inline-script hashes into _headers
scripts/check.mjs    checks a running copy of the site
src/content.ts       every word on the page
src/release.ts       the newest version, looked up at build time
src/version.ts       that version, as the page reads it
src/pictures.ts      the app pictures and the widths they are made in
src/router.tsx       the router TanStack Start uses
src/routes/          __root (the <head>, header and footer), index (the page), 404
src/routeTree.gen.ts made from src/routes by the router's plugin on each dev run or build; keep it
src/components/      one file per section of the page, and a few small pieces
src/styles/          the one stylesheet: colours, type, the hero's motion
src/fonts/           the serif typeface
src/images/          pictures of the app
```

The look follows the app: black and white with neutral greys, no accent colour, few boxes. See [`packages/ui/COMPONENTS.md`](../../packages/ui/COMPONENTS.md). The only motion is CSS: the pill's bars, and the words at the top arriving once. People who ask their system for less motion see the finished state at once.

## Licence

[MIT](../../LICENSE), like the rest of the project.
