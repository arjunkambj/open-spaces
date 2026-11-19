// The newest release, looked up once while the site is built and written into the HTML.
// A visitor's browser asks GitHub nothing.

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { links } from "./content";

export interface Release {
  /** For example "0.1.0". */
  version: string;
  /** Where the Download button goes. */
  downloadUrl: string;
}

let cached: Promise<Release> | undefined;

/** The newest release on GitHub, or the version in apps/macos/package.json when GitHub cannot be reached. */
export function latestRelease(): Promise<Release> {
  cached ??= fromGitHub().catch(async (error: unknown) => {
    const version = await fromPackage();
    const reason = error instanceof Error ? error.message : String(error);
    console.warn(`release: GitHub did not answer (${reason}). Using version ${version} from apps/macos/package.json.`);
    return { version, downloadUrl: links.download };
  });
  return cached;
}

// GitHub sends "/releases/latest" on to the newest release, and the address it sends to
// ends in the tag. Reading that needs no API key and has no hourly limit.
async function fromGitHub(): Promise<Release> {
  const newest = `${links.releases}/latest`;
  const target = (await ask(newest)).headers.get("location") ?? "";
  const version = /\/releases\/tag\/v?(\d+\.\d+\.\d+[^/]*)$/.exec(target)?.[1];
  if (!version) throw new Error("the newest release has no version tag");
  // A release made before the fixed-name file existed: send people to the release page instead.
  const hasFile = (await ask(links.download)).status === 302;
  console.log(`release: ${version} from GitHub${hasFile ? "" : ", which has no file with the fixed name"}`);
  return { version, downloadUrl: hasFile ? links.download : newest };
}

function ask(address: string): Promise<Response> {
  return fetch(address, { method: "HEAD", redirect: "manual", signal: AbortSignal.timeout(8000) });
}

async function fromPackage(): Promise<string> {
  // The build runs in apps/web.
  const file = resolve(process.cwd(), "../macos/package.json");
  const { version } = JSON.parse(await readFile(file, "utf8")) as { version: string };
  return version;
}
