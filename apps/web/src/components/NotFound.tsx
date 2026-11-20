import { notFound } from "../content";

export function NotFound() {
  return (
    <main id="main" className="frame py-28 sm:py-40">
      <p className="label">404</p>
      <h1 className="display mt-3 text-[clamp(2.75rem,7vw,6rem)] leading-[0.98]">{notFound.title}</h1>
      <p className="mt-5 text-lg text-neutral-600 dark:text-neutral-300">{notFound.text}</p>
      <p className="mt-8">
        <a href="/" className="link">
          {notFound.link}
        </a>
      </p>
    </main>
  );
}
