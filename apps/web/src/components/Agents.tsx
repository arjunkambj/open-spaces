import { agents, links } from "../content";
import { CopyButton } from "./CopyButton";

/** The one dark band on the page: the part that happens in a terminal. */
export function Agents() {
  return (
    <section
      id="agents"
      className="bg-neutral-900 text-neutral-100 dark:border-y dark:border-white/10 dark:bg-neutral-900"
    >
      <div className="frame py-24 sm:py-32">
        <h2 className="display max-w-[16em] text-[clamp(2.5rem,5vw,4rem)] leading-[1.02]">{agents.title}</h2>
        <p className="mt-5 max-w-2xl text-lg text-pretty text-neutral-300">{agents.lead}</p>

        <div className="mt-14 grid gap-x-16 gap-y-12 lg:grid-cols-2">
          <div className="min-w-0">
            <div className="flex items-end justify-between gap-4">
              <p className="label text-neutral-400">{agents.setupLabel}</p>
              <CopyButton text={agents.command} />
            </div>
            <pre className="mt-3 rounded-xl bg-black/35 p-5 font-mono text-[13px] leading-6 break-words whitespace-pre-wrap text-neutral-100 ring-1 ring-white/10 ring-inset sm:text-sm">
              <span className="text-neutral-500 select-none" aria-hidden="true">
                ${" "}
              </span>
              <code>{agents.command}</code>
            </pre>
            <p className="mt-3 text-sm text-pretty text-neutral-400">{agents.otherTools}</p>
          </div>

          <div>
            <p className="label text-neutral-400">{agents.examplesLabel}</p>
            <ul className="mt-3 border-t border-white/10">
              {agents.examples.map((example) => (
                <li
                  key={example.tool}
                  className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 border-b border-white/10 py-4"
                >
                  <span className="font-serif text-xl text-pretty">“{example.ask}”</span>
                  <code className="font-mono text-[13px] text-neutral-400">{example.tool}</code>
                </li>
              ))}
            </ul>
          </div>
        </div>

        <div className="mt-14 max-w-2xl text-[15px] text-pretty text-neutral-400">
          <p>{agents.limits}</p>
          <p className="mt-2">{agents.caution}</p>
          <p className="mt-5">
            <a
              href={links.agentGuide}
              className="text-white font-medium underline decoration-current/35 underline-offset-4 hover:decoration-current"
            >
              {agents.guideLink}
            </a>
          </p>
        </div>
      </div>
    </section>
  );
}
