import { footer } from "../content";
import { Brand } from "./Brand";

export function Footer() {
  return (
    <footer className="border-t border-neutral-900/10 dark:border-white/10">
      <div className="frame flex flex-wrap items-start justify-between gap-x-10 gap-y-6 py-10">
        <div>
          <Brand />
          <p className="mt-4 max-w-xl text-sm text-pretty text-neutral-500 dark:text-neutral-400">{footer.independent}</p>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">{footer.pictures}</p>
        </div>
        <ul className="flex flex-wrap gap-x-6 gap-y-2 text-[15px]">
          {footer.links.map((link) => (
            <li key={link.href}>
              <a href={link.href} className="text-neutral-600 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-white">
                {link.label}
              </a>
            </li>
          ))}
        </ul>
      </div>
    </footer>
  );
}
