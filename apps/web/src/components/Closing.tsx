import { closing, download } from "../content";
import { version } from "../version";
import { DownloadButton } from "./DownloadButton";

export function Closing() {
  return (
    <section id="get" className="border-t border-neutral-900/10 dark:border-white/10">
      <div className="frame grid gap-x-16 gap-y-12 py-24 sm:py-32 lg:grid-cols-[7fr_5fr] lg:items-end">
        <div>
          <h2 className="display text-[clamp(2.75rem,7vw,6rem)] leading-[0.98]">{closing.title}</h2>
          <p className="mt-6 text-lg text-neutral-600 dark:text-neutral-300">{closing.lead}</p>
          <div className="mt-8">
            <DownloadButton />
          </div>
          <p className="mt-4 text-sm text-neutral-600 dark:text-neutral-400">
            {`Version ${version} · ${download.requirements}`}
          </p>
        </div>

        <div className="text-[15px] text-pretty text-neutral-600 dark:text-neutral-300">
          <p>{closing.openSource}</p>
          <ul className="mt-5 flex flex-wrap gap-x-6 gap-y-2">
            {closing.links.map((link) => (
              <li key={link.href}>
                <a href={link.href} className="link">
                  {link.label}
                </a>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  );
}
