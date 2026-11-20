import { type Picture, pictureFormats, pictureUrl, type Scheme, widthsOf } from "../pictures";

/**
 * A picture of the app that follows light and dark mode, in the sizes and formats a browser
 * can choose from. The width and height are set, so the page does not jump while it loads.
 */
export function AppPicture({
  picture,
  alt,
  sizes,
  first = false,
}: {
  picture: Picture;
  alt: string;
  /** How wide the picture is shown, as the browser's `sizes` rule. */
  sizes: string;
  /** For the picture at the top of the page: load it at once. */
  first?: boolean;
}) {
  const widths = widthsOf(picture);
  const srcSet = (scheme: Scheme, format: (typeof pictureFormats)[number]) =>
    widths.map((width) => `${pictureUrl(picture, scheme, width, format)} ${width}w`).join(", ");
  const schemes: { scheme: Scheme; media?: string }[] = [
    { scheme: "dark", media: "(prefers-color-scheme: dark)" },
    { scheme: "light" },
  ];

  return (
    <picture>
      {schemes.flatMap(({ scheme, media }) =>
        pictureFormats.map((format) => (
          <source
            key={`${scheme}-${format}`}
            media={media}
            type={`image/${format}`}
            srcSet={srcSet(scheme, format)}
            sizes={sizes}
          />
        )),
      )}
      <img
        src={pictureUrl(picture, "light", Math.min(1280, picture.width), "webp")}
        width={picture.width}
        height={picture.height}
        alt={alt}
        loading={first ? "eager" : "lazy"}
        fetchPriority={first ? "high" : "auto"}
        decoding="async"
        className="block h-auto w-full"
      />
    </picture>
  );
}
