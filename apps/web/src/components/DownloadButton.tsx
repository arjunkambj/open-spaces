import { download, links } from "../content";

export function DownloadButton({ size = "large" }: { size?: "small" | "large" }) {
  if (size === "small") {
    return (
      <a href={links.download} className="button h-9 px-4 text-sm">
        {download.shortButton}
      </a>
    );
  }
  return (
    <a href={links.download} className="button h-12 px-6 text-base">
      <svg
        viewBox="0 0 20 20"
        width="18"
        height="18"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        <path d="M10 3v10m0 0 4-4m-4 4-4-4M4 16.5h12" />
      </svg>
      {download.button}
    </a>
  );
}
