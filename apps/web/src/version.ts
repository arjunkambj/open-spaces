// The newest release, looked up once while the site is built (src/release.ts, called from
// vite.config.ts) and written into the page. A visitor's browser asks GitHub nothing.
declare const __SPACES_VERSION__: string;

/** For example "0.1.2". */
export const version: string = __SPACES_VERSION__;
