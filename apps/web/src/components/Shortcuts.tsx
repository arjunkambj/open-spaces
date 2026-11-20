import { Fragment } from "react";
import { shortcuts } from "../content";

export function Shortcuts() {
  return (
    <section id="dictation" className="frame grid gap-x-16 gap-y-10 py-24 sm:py-32 lg:grid-cols-[5fr_7fr]">
      <div>
        <h2 className="display text-[clamp(2.5rem,5vw,4rem)] leading-[1.02]">{shortcuts.title}</h2>
        <p className="mt-5 max-w-md text-lg text-pretty text-stone-600 dark:text-stone-300">{shortcuts.extras}</p>
      </div>

      <div>
        <p className="label">{shortcuts.lead}</p>
        <dl className="mt-4 border-t border-stone-900/10 dark:border-white/10">
          {shortcuts.items.map((shortcut) => (
            <div
              key={shortcut.name}
              className="grid gap-x-8 gap-y-3 border-b border-stone-900/10 py-5 sm:grid-cols-[16rem_1fr] dark:border-white/10"
            >
              <dt className="flex flex-wrap items-center gap-1.5">
                {shortcut.keys.map((key, index) => (
                  <Fragment key={key}>
                    {index > 0 && (
                      <span className="text-stone-400" aria-hidden="true">
                        +
                      </span>
                    )}
                    <kbd className="key">{key}</kbd>
                  </Fragment>
                ))}
              </dt>
              <dd>
                <span className="font-semibold">{shortcut.name}.</span>{" "}
                <span className="text-stone-600 dark:text-stone-300">{shortcut.text}</span>
              </dd>
            </div>
          ))}
        </dl>
      </div>
    </section>
  );
}
