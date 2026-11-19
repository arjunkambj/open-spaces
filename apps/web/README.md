# The Open Wisper website

One page that says what Open Wisper is and lets people download it: <https://whisper.0xhoney.com>.

It is a static site: plain HTML, one CSS file and pictures. No JavaScript is sent to the browser. There are no analytics, no cookies, no fonts or scripts from other sites. The only links that leave the page go to GitHub.

Built with [Astro](https://astro.build) (it turns the files in `src` into HTML) and [Tailwind CSS](https://tailwindcss.com) (the styling). It is served by [Cloudflare Workers](https://developers.cloudflare.com/workers/static-assets/) as plain files.

## Run it

You need Node.js 22 or newer and pnpm. From the repository root:

```bash
pnpm install        # once
pnpm web            # the page at http://127.0.0.1:4321, updating as you edit
pnpm web:build      # the finished site, in apps/web/dist
```

To see the finished site the way Cloudflare serves it, with the real response headers and the 404 page:

```bash
pnpm web:build
pnpm --filter @open-wisper/web run preview       # http://127.0.0.1:8788
```

Two checks:

```bash
pnpm --filter @open-wisper/web run lint          # the types, in every file
pnpm --filter @open-wisper/web run check:site    # the live site: links, files, headers, version
```

`check:site` takes another address too, such as the preview: `pnpm --filter @open-wisper/web run check:site http://127.0.0.1:8788`.

## Change the words

Every word on the page is in one file: [`src/content.ts`](src/content.ts). Edit the text there and run `pnpm web` to see it.

Keep it plain English: short sentences, everyday words. Say only what is true of the app as it ships. The root [README](../../README.md) is the reference for that.

The line for connecting an AI agent, and the tool names in the Agents section, are copied from [`docs/agents.md`](../../docs/agents.md). When they change there, change them here.

## Change the pictures

| Picture | File | Where it comes from |
| --- | --- | --- |
| The app window at the top | `src/images/home-light.png`, `home-dark.png` | The Mac app's own snapshot tool, screen `mac-hub-home` |
| The meeting | `src/images/meeting-light.png`, `meeting-dark.png` | The shared snapshot tool, screen `meeting-notes` |
| The app icon, the browser-tab icons | `../../assets/icon-1024.png` | The app's icon. Nothing to copy: the next build picks up a new one |
| The picture shown when the link is shared | made by `src/artwork.ts` | The icon, the window picture and two lines of text |
| The small pill with moving bars | `src/components/Pill.astro` | Drawn with CSS |

To make fresh pictures of the app, with no window opened (see "Commands" in [AGENTS.md](../../AGENTS.md)):

```bash
"apps/macos/build/Open Wisper.app/Contents/MacOS/OpenWisper" --snapshots <folder>   # the Mac window
cd packages/ui && ../../scripts/swiftw run wisper-snapshots <folder>                # shared screens
```

Copy the light and the dark picture over the files above. Both must have the same size. All pictures show made-up sample data; keep it that way.

The build makes each picture in several sizes, as AVIF and WebP, and the browser takes the one that fits.

## The version and the Download button

The button goes to

```
https://github.com/arjunkambj/open-wisper/releases/latest/download/Open-Wisper.dmg
```

GitHub sends that address on to the newest release. The Release workflow attaches the disk image twice: as `Open-Wisper-<version>.dmg` (the one installed apps update from) and as `Open-Wisper.dmg`, so this address never changes.

The version next to the button is looked up **while the site is built** ([`src/release.ts`](src/release.ts)) and written into the HTML. A visitor's browser asks GitHub nothing.

- The build asks GitHub where `releases/latest` leads. The answer ends in the tag, such as `v0.1.0`.
- If GitHub does not answer, it uses the version in `apps/macos/package.json`.

The page only changes when the site is built again. That is why a new release deploys the site (see below).

## How it gets to Cloudflare

The site is one Cloudflare Worker named `open-wisper-web`. It has no code: it only serves the files in `dist`. [`wrangler.jsonc`](wrangler.jsonc) describes it.

- **Address.** `whisper.0xhoney.com` is a "custom domain" of the Worker. Cloudflare makes the DNS record and the certificate by itself. The `*.workers.dev` address and the preview addresses are turned off, so there is one address.
- **Headers.** [`public/_headers`](public/_headers) sets them: a Content-Security-Policy that allows only the site's own files, HSTS, and the usual hardening headers. Files under `/_astro/` carry a fingerprint in their name and are kept by browsers for a year. The page itself is checked again on every visit.
- **Nothing is added on the way.** The `0xhoney.com` domain has Cloudflare Web Analytics switched on, which adds a tracking script to every page of the domain. Every file here is sent with `Cache-Control: no-transform`, which tells Cloudflare to leave it alone, and the Content-Security-Policy would refuse the script anyway. `check:site` fails if a script ever shows up. Do not remove `no-transform`.
- **Plain `http://`.** The site answers on `http://` as well as `https://`. Sending everyone to `https://` is a switch for the whole domain (Cloudflare dashboard: the domain > SSL/TLS > Edge Certificates > **Always Use HTTPS**), so it is left to the domain's owner. Browsers that have visited once use `https://` by themselves (HSTS).
- **404.** An address that does not exist gets `404.html` with status 404.
- Also in `public`: `robots.txt` and `sitemap.xml`.

### Deploy from your Mac

```bash
pnpm web:deploy     # builds, then runs `wrangler deploy`
```

Wrangler (Cloudflare's command-line tool, installed with `pnpm install`) must be allowed into **the Cloudflare account that holds the `0xhoney.com` domain**. A Worker can only be given an address on a domain of its own account. No account ID is kept in this repository. Either:

- keep a token and the account ID in a private file outside the repository, and load it for the one command. The maintainer's Mac has `~/.config/open-wisper/cloudflare.env`, two lines (`CLOUDFLARE_API_TOKEN=...` and `CLOUDFLARE_ACCOUNT_ID=...`), readable only by its owner:

  ```bash
  (set -a; source ~/.config/open-wisper/cloudflare.env; pnpm web:deploy)
  ```

- or sign in once with `pnpm --filter @open-wisper/web exec wrangler login` (it opens a browser; choose that account). If the sign-in reaches more than one account, also set `CLOUDFLARE_ACCOUNT_ID`.

Then check the result: `pnpm --filter @open-wisper/web run check:site`.

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
astro.config.ts     site address, Tailwind
wrangler.jsonc      the Cloudflare Worker and its address
public/             files served as they are: _headers, robots.txt, sitemap.xml
scripts/check.mjs   checks a running copy of the site
src/content.ts      every word on the page
src/release.ts      the newest version, looked up at build time
src/artwork.ts      the icons and the social preview picture, made at build time
src/components/     one file per section of the page
src/layouts/        the <head>: title, description, social tags
src/pages/          index (the page), 404, and the made pictures
src/styles/         the one stylesheet: colours, fonts, a few shared pieces
src/images/         pictures of the app
```

The look follows the app: the warm "stone" greys, the app's pine green as the one accent, the system font, few boxes. See [`packages/ui/COMPONENTS.md`](../../packages/ui/COMPONENTS.md).

## Licence

[MIT](../../LICENSE), like the rest of the project.
