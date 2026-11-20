import { meetings } from "../content";
import { pictures } from "../pictures";
import { AppPicture } from "./AppPicture";

export function Meetings() {
  return (
    <section id="meetings" className="border-t border-stone-900/10 dark:border-white/10">
      <div className="frame grid items-center gap-x-16 gap-y-12 py-24 sm:py-32 lg:grid-cols-[7fr_5fr]">
        <div className="lg:order-last">
          <h2 className="display text-[clamp(2.5rem,5vw,4rem)] leading-[1.02]">{meetings.title}</h2>
          {meetings.text.map((paragraph) => (
            <p key={paragraph} className="mt-5 text-lg text-pretty text-stone-600 dark:text-stone-300">
              {paragraph}
            </p>
          ))}
          <p className="mt-6 text-[15px] text-pretty text-stone-500 dark:text-stone-400">{meetings.crash}</p>
        </div>
        <div className="window">
          <AppPicture
            picture={pictures.meeting}
            alt={meetings.pictureAlt}
            sizes="(min-width: 1216px) 640px, (min-width: 1024px) 55vw, calc(100vw - 32px)"
          />
        </div>
      </div>
    </section>
  );
}
