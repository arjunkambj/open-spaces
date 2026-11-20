// The pictures of the app on the page. artwork.ts makes each one at build time in the widths
// below, as AVIF and WebP, from src/images/<name>-light.png and <name>-dark.png.

export interface Picture {
  name: string;
  /** The size of the source PNGs. The light and the dark one must match. */
  width: number;
  height: number;
}

export const pictures = {
  home: { name: "home", width: 2360, height: 1560 },
  meeting: { name: "meeting", width: 1760, height: 1440 },
} as const satisfies Record<string, Picture>;

export const pictureFormats = ["avif", "webp"] as const;
export type PictureFormat = (typeof pictureFormats)[number];
export type Scheme = "light" | "dark";

const allWidths = [640, 960, 1280, 1760, 2360];

/** The widths a picture is made in: none wider than its source. */
export function widthsOf(picture: Picture): number[] {
  return allWidths.filter((width) => width <= picture.width);
}

/** Where one made file of a picture is served. */
export function pictureUrl(picture: Picture, scheme: Scheme, width: number, format: PictureFormat): string {
  return `/pictures/${picture.name}-${scheme}-${width}.${format}`;
}
