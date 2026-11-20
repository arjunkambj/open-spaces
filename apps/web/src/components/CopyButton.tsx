import { useEffect, useState } from "react";
import { copy } from "../content";

/**
 * Copies a line to the clipboard. It needs the page's script, so it only shows once that has
 * run: without it, the line can still be selected and copied by hand.
 */
export function CopyButton({ text }: { text: string }) {
  const [ready, setReady] = useState(false);
  const [copied, setCopied] = useState(false);
  useEffect(() => setReady(true), []);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1800);
    return () => clearTimeout(timer);
  }, [copied]);

  if (!ready) return null;
  return (
    <button
      type="button"
      onClick={() => navigator.clipboard.writeText(text).then(() => setCopied(true))}
      className="rounded-md px-2 py-1 font-sans text-xs font-medium text-stone-300 ring-1 ring-white/15 transition-colors duration-150 hover:bg-white/10 hover:text-white"
    >
      <span aria-live="polite">{copied ? copy.done : copy.button}</span>
    </button>
  );
}
