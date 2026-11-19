// Pictures drawn while the site is built: the browser-tab icons and the social preview image.
// They start from the app icon in assets/, so a new icon shows up here on the next build.

import { resolve } from "node:path";
import sharp from "sharp";
import { hero, site } from "./content";

// The build runs in apps/web.
const appIcon = resolve(process.cwd(), "../../assets/icon-1024.png");
const windowPicture = resolve(process.cwd(), "src/images/home-light.png");

const paper = "#f5f5f4"; // stone-100
const ink = "#1c1917"; // stone-900
const quiet = "#57534e"; // stone-600

/** The app icon as a square PNG. With `background`, the clear corners are filled in. */
export function iconPng(size: number, background?: string): Promise<Buffer> {
  const icon = sharp(appIcon).resize(size, size);
  return (background ? icon.flatten({ background }) : icon).png().toBuffer();
}

/** A favicon.ico holding one 32-pixel PNG, which every current browser reads. */
export async function faviconIco(): Promise<Buffer> {
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
export async function socialImage(): Promise<Buffer> {
  const width = 1200;
  const height = 630;
  // The top of the app window, running off the bottom edge.
  const shot = { left: 80, top: 280, width: 1040, height: height - 280 };
  const corners = Buffer.from(
    `<svg width="${shot.width}" height="${shot.height}"><rect width="${shot.width}" height="${shot.height + 40}" rx="20"/></svg>`,
  );
  const window = await sharp(windowPicture)
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
