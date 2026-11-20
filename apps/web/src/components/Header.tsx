import { nav } from "../content";
import { Brand } from "./Brand";
import { DownloadButton } from "./DownloadButton";

export function Header() {
  return (
    <header className="frame flex h-16 items-center justify-between gap-6 sm:h-20">
      <Brand />
      <nav aria-label="Main" className="flex items-center gap-6 text-[15px]">
        {nav.map((item, index) => (
          <a
            key={item.href}
            href={item.href}
            className={`text-stone-600 hover:text-stone-900 dark:text-stone-400 dark:hover:text-white ${
              index < nav.length - 1 ? "hidden md:block" : ""
            }`}
          >
            {item.label}
          </a>
        ))}
        <DownloadButton size="small" />
      </nav>
    </header>
  );
}
