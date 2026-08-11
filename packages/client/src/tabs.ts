/** The three places in the game. Kept as data so the navbar and the router stay in step. */
export const TABS = [
  { id: "forge", label: "La Forgia" },
  { id: "sanctuary", label: "Santuario" },
  { id: "arena", label: "L'Arena" },
] as const;

export type TabId = (typeof TABS)[number]["id"];

export const DEFAULT_TAB: TabId = "forge";
