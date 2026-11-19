import type { APIRoute } from "astro";
import { iconPng } from "../artwork";

export const GET: APIRoute = async () =>
  new Response(new Uint8Array(await iconPng(180, "#f5f5f4")), { headers: { "Content-Type": "image/png" } });
