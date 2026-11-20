// Pictures made from the app's own files while the site is built: the browser-tab icons, the
// social preview image, and every app picture in several widths as AVIF and WebP.
// `artwork()` is a Vite plugin. In `vite dev` it makes each file the first time it is asked
// for; in `vite build` it adds them all to the files of the site.

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import type { Plugin } from "vite";
import { hero, site } from "./src/content.ts";
import { type Picture, pictureFormats, pictureUrl, pictures, widthsOf } from "./src/pictures.ts";

const root = fileURLToPath(new URL(".", import.meta.url));
const appIcon = resolve(root, "../../assets/icon-1024.png");
const source = (picture: Picture, scheme: string) => resolve(root, `src/images/${picture.name}-${scheme}.png`);

const paper = "#ffffff"; // the app's panel white
const ink = "#0d0d0d"; // the app's ink
const quiet = "#5d5d5d"; // the app's secondary grey

/** The app icon as a square PNG. With `background`, the clear corners are filled in. */
function iconPng(size: number, background?: string): Promise<Buffer> {
  const icon = sharp(appIcon).resize(size, size);
  return (background ? icon.flatten({ background }) : icon).png().toBuffer();
}

/** A favicon.ico holding one 32-pixel PNG, which every current browser reads. */
async function faviconIco(): Promise<Buffer> {
  const png = await iconPng(32);
  const header = Buffer.alloc(22);
  header.writeUInt16LE(1, 2); // type: icon
  header.writeUInt16LE(1, 4); // one picture
  header.writeUInt8(32, 6); // width
  header.writeUInt8(32, 7); // height
  header.writeUInt16LE(1, 10); // colour planes
  header.writeUInt16LE(32, 12); // bits per pixel
  header.writeUInt32LE(png.length, 14);
  header.writeUInt32LE(header.length, 18); // where the PNG starts
  return Buffer.concat([header, png]);
}

/** The 1200 by 630 picture that chat apps and social sites show next to a link. */
async function socialImage(): Promise<Buffer> {
  const width = 1200;
  const height = 630;
  // The top of the app window, running off the bottom edge.
  const shot = { left: 80, top: 280, width: 1040, height: height - 280 };
  const corners = Buffer.from(
    `<svg width="${shot.width}" height="${shot.height}"><rect width="${shot.width}" height="${shot.height + 40}" rx="20"/></svg>`,
  );
  const window = await sharp(source(pictures.home, "light"))
    .resize({ width: shot.width })
    .extract({ left: 0, top: 0, width: shot.width, height: shot.height })
    .composite([{ input: corners, blend: "dest-in" }])
    .png()
    .toBuffer();
  const sans = "'Helvetica Neue', Helvetica, Arial, 'Liberation Sans', 'DejaVu Sans', sans-serif";
  const words = Buffer.from(
    `<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      <text x="176" y="118" font-family="${sans}" font-size="44" font-weight="700" fill="${ink}">${site.name}</text>
      <text x="80" y="212" font-family="${sans}" font-size="34" fill="${quiet}">${hero.headline} Voice dictation and meeting notes for Mac.</text>
      <rect x="${shot.left - 1}" y="${shot.top - 1}" width="${shot.width + 2}" height="${shot.height + 40}" rx="21" fill="none" stroke="${ink}" stroke-opacity="0.14" stroke-width="2"/>
    </svg>`,
  );
  return sharp({ create: { width, height, channels: 3, background: paper } })
    .composite([
      { input: await iconPng(88), left: 76, top: 58 },
      { input: window, left: shot.left, top: shot.top },
      { input: words, left: 0, top: 0 },
    ])
    .png({ compressionLevel: 9 })
    .toBuffer();
}

/** Every made file, by its path on the site, with the work that makes it. */
function makers(): Map<string, () => Promise<Buffer>> {
  const files = new Map<string, () => Promise<Buffer>>([
    ["favicon.ico", faviconIco],
    ["icon.png", () => iconPng(192)],
    ["brand.png", () => iconPng(96)],
    ["apple-touch-icon.png", () => iconPng(180, paper)],
    ["og.png", socialImage],
  ]);
  for (const picture of Object.values(pictures)) {
    for (const scheme of ["light", "dark"] as const) {
      for (const width of widthsOf(picture)) {
        for (const format of pictureFormats) {
          files.set(pictureUrl(picture, scheme, width, format).slice(1), async () => {
            const resized = sharp(await readFile(source(picture, scheme))).resize({ width });
            return format === "avif"
              ? resized.avif({ quality: 62, effort: 4 }).toBuffer()
              : resized.webp({ quality: 82 }).toBuffer();
          });
        }
      }
    }
  }
  return files;
}

const types: Record<string, string> = {
  ico: "image/x-icon",
  png: "image/png",
  avif: "image/avif",
  webp: "image/webp",
};

export function artwork(): Plugin {
  const files = makers();
  const made = new Map<string, Promise<Buffer>>();
  const make = (path: string): Promise<Buffer> | undefined => {
    const maker = files.get(path);
    if (!maker) return undefined;
    const file = made.get(path) ?? maker();
    made.set(path, file);
    return file;
  };

  return {
    name: "open-spaces:artwork",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        const path = (request.url ?? "").split("?")[0]?.slice(1) ?? "";
        const file = make(path);
        if (!file) return next();
        file.then(
          (buffer) => {
            response.setHeader("Content-Type", types[path.split(".").pop() ?? ""] ?? "application/octet-stream");
            response.end(buffer);
          },
          (error: unknown) => next(error),
        );
      });
    },
    async generateBundle() {
      if (this.environment.name !== "client") return;
      for (const [path, maker] of files) {
        this.emitFile({ type: "asset", fileName: path, source: await (made.get(path) ?? maker()) });
      }
    },
  };
}
