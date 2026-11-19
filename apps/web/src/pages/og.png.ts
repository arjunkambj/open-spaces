import type { APIRoute } from "astro";
import { socialImage } from "../artwork";

export const GET: APIRoute = async () =>
  new Response(new Uint8Array(await socialImage()), { headers: { "Content-Type": "image/png" } });
