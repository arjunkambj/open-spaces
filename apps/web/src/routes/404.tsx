import { createFileRoute } from "@tanstack/react-router";
import { NotFound } from "../components/NotFound";

// Prerendered as dist/client/404.html. Cloudflare sends that file, with status 404, for any
// address that does not exist; in the browser the root route's notFoundComponent shows the same.
export const Route = createFileRoute("/404")({ component: NotFound });
