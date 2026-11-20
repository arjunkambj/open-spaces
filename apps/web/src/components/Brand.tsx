import { site } from "../content";

/** The app icon and the name. The icon is the app's own, from assets/ at the repo root. */
export function Brand() {
  return (
    <a href="/" className="flex items-center gap-2">
      <img src="/brand.png" alt="" width={32} height={32} className="size-8" />
      <span className="font-rounded text-[17px] font-semibold tracking-tight">{site.name}</span>
    </a>
  );
}
