import { privacy } from "../content";

export function Privacy() {
  return (
    <section id="privacy" className="frame py-24 sm:py-32">
      <h2 className="display text-[clamp(2.25rem,4vw,3.25rem)] leading-[1.05]">{privacy.title}</h2>
      <p className="mt-4 max-w-2xl text-lg text-pretty text-neutral-600 dark:text-neutral-300">{privacy.lead}</p>

      <div className="mt-12 grid gap-x-10 gap-y-10 border-t border-neutral-900/10 pt-8 md:grid-cols-3 dark:border-white/10">
        {privacy.columns.map((column) => (
          <div key={column.title}>
            <h3 className="label">{column.title}</h3>
            <ul className="mt-4 space-y-3 text-[15px] text-pretty text-neutral-700 dark:text-neutral-300">
              {column.items.map((item) => (
                <li key={item}>{item}</li>
              ))}
            </ul>
          </div>
        ))}
      </div>
      <p className="mt-10 max-w-3xl text-sm text-pretty text-neutral-500 dark:text-neutral-400">{privacy.note}</p>
      <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">{privacy.thisPage}</p>
    </section>
  );
}
