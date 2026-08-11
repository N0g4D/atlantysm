/**
 * Atlantysm — Pastel Solarpunk design tokens.
 *
 * The look is line-art: flat fills, thin `ink` outlines, no gradients on components and no soft
 * shadows. Depth comes from a hard offset shadow in the same ink colour, which is why there is a
 * `boxShadow.line` token instead of Tailwind's blurred defaults.
 *
 * `ink` replaces black everywhere on purpose — pure #000 against an off-white ground reads harsh
 * and flattens the pastels next to it.
 *
 * @type {import('tailwindcss').Config}
 */
module.exports = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        offwhite: "#F8FAFC",
        ink: "#2E3454",
        /** Grid rule colour. Deliberately near-invisible: it should read as paper, not as a table. */
        grid: "#DCE8F7",
        solarpunk: {
          lavender: "#C4B5FD",
          mint: "#A7F3D0",
          peach: "#FFD8CB",
        },
      },
      backgroundImage: {
        /** Two 1px rules crossed — cheaper and crisper than an SVG at any zoom level. */
        "grid-pattern":
          "linear-gradient(to right, #DCE8F7 1px, transparent 1px), linear-gradient(to bottom, #DCE8F7 1px, transparent 1px)",
      },
      backgroundSize: {
        /**
         * NOT named `grid`: a `colors.grid` entry already exists, and Tailwind would emit `bg-grid`
         * for both — the colour wins, silently overriding `bg-offwhite` and painting the page a
         * solid pale blue. Only a render catches that; the build is perfectly happy.
         */
        "grid-32": "32px 32px",
      },
      boxShadow: {
        /** The only elevation in the system: a hard ink offset, no blur. */
        line: "3px 3px 0 0 #2E3454",
        "line-sm": "2px 2px 0 0 #2E3454",
      },
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["ui-monospace", "SFMono-Regular", "Menlo", "monospace"],
      },
    },
  },
  plugins: [],
};
