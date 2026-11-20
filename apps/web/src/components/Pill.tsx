/**
 * A drawing of the floating pill while it listens. Its look and its moving bars are in
 * src/styles/global.css (.pill). The bars stand still for people who ask for less motion.
 */
export function Pill({ label }: { label: string }) {
  return (
    <div role="img" aria-label={label} className="pill">
      {Array.from({ length: 9 }, (_, index) => (
        <span key={index} />
      ))}
    </div>
  );
}
