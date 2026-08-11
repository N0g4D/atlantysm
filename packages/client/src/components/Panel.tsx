import type { ReactNode } from "react";

type Props = {
  title: string;
  hint?: string;
  accent?: "lavender" | "mint" | "peach";
  children?: ReactNode;
};

const ACCENTS = {
  lavender: "bg-solarpunk-lavender",
  mint: "bg-solarpunk-mint",
  peach: "bg-solarpunk-peach",
} as const;

/** The single surface shape in the app: an ink outline, a pastel header rule, a white body. */
export function Panel({ title, hint, accent = "lavender", children }: Props) {
  return (
    <section className="panel">
      <div className={`flex items-baseline gap-3 border-b-2 border-ink px-5 py-3 ${ACCENTS[accent]}`}>
        <h2 className="heading">{title}</h2>
        {hint ? <span className="text-xs text-ink/70">{hint}</span> : null}
      </div>
      <div className="px-5 py-5">{children}</div>
    </section>
  );
}

/** Label/value row. Values are monospace so numbers line up between rows. */
export function Stat({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b border-dashed border-ink/25 py-2 last:border-b-0">
      <span className="muted">{label}</span>
      <span className="font-mono text-sm">{value}</span>
    </div>
  );
}
