import { Fragment } from "react";
import { download, hero, links } from "../content";
import { pictures } from "../pictures";
import { version } from "../version";
import { AppPicture } from "./AppPicture";
import { DownloadButton } from "./DownloadButton";
import { Pill } from "./Pill";

/** What you say, and what lands. The words arrive in turn; the timing is in global.css. */
export function Hero() {
  const typed = hero.typed.split(" ");
  return (
    <section id="download" className="frame pt-6 sm:pt-10 lg:pt-12">
      <figure>
        <p className="label">{hero.saidLabel}</p>
        <div className="mt-3 flex items-center gap-4">
          <Pill label={hero.pillLabel} />
          <p className="said font-mono text-base text-stone-500 sm:text-lg dark:text-stone-400">
            {hero.said.map((word, index) => (
              <Fragment key={index}>
                {index > 0 && " "}
                <span className={"filler" in word ? "word filler" : "word"}>{word.text}</span>
              </Fragment>
            ))}
          </p>
        </div>

        <p className="label mt-8 sm:mt-10">{hero.typedLabel}</p>
        <p className="typed display mt-2 max-w-[13em] text-[clamp(2.75rem,7.2vw,6.25rem)] leading-[0.98]">
          {typed.map((word, index) => (
            <Fragment key={index}>
              {index > 0 && " "}
              <span className="word inline-block">{word}</span>
            </Fragment>
          ))}
          <span className="caret" aria-hidden="true" />
        </p>
      </figure>

      <div className="mt-10 grid gap-x-16 gap-y-8 border-t border-stone-900/10 pt-8 sm:mt-12 lg:grid-cols-[minmax(0,1fr)_auto] dark:border-white/10">
        <div className="max-w-xl">
          <h1 className="text-2xl font-semibold tracking-tight sm:text-[28px]">{hero.headline}</h1>
          <p className="mt-3 text-lg text-pretty text-stone-600 dark:text-stone-300">{hero.lead}</p>
        </div>
        <div className="lg:max-w-sm">
          <div className="flex flex-wrap items-center gap-x-5 gap-y-3">
            <DownloadButton />
            <span className="text-sm text-stone-500 dark:text-stone-400">{hero.status}</span>
          </div>
          <p className="mt-4 text-sm text-stone-600 dark:text-stone-400">
            {`Version ${version} · ${download.requirements}`}
          </p>
          <p className="mt-1 text-sm text-pretty text-stone-600 dark:text-stone-400">
            {download.firstLaunch}{" "}
            <a href={links.install} className="link">
              {download.firstLaunchLink}
            </a>
          </p>
        </div>
      </div>

      <figure className="mt-16 sm:mt-24">
        <div className="window">
          <AppPicture
            picture={pictures.home}
            alt={hero.pictureAlt}
            sizes="(min-width: 1216px) 1152px, (min-width: 640px) calc(100vw - 64px), calc(100vw - 32px)"
            first
          />
        </div>
        <figcaption className="label mt-4">{hero.pictureCaption}</figcaption>
      </figure>
    </section>
  );
}
