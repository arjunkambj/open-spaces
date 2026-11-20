import { createFileRoute } from "@tanstack/react-router";
import { Agents } from "../components/Agents";
import { Closing } from "../components/Closing";
import { Hero } from "../components/Hero";
import { Meetings } from "../components/Meetings";
import { Privacy } from "../components/Privacy";
import { Shortcuts } from "../components/Shortcuts";

export const Route = createFileRoute("/")({ component: Home });

function Home() {
  return (
    <main id="main">
      <Hero />
      <Shortcuts />
      <Meetings />
      <Agents />
      <Privacy />
      <Closing />
    </main>
  );
}
