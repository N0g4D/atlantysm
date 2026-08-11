import { createContext, useContext, type ReactNode } from "react";

import type { SetupResult } from "./setup";

/**
 * Holds the result of the one-time MUD bootstrap.
 *
 * `setup()` is awaited before React mounts (see index.tsx), so the value is never null in practice
 * and no component has to handle a loading state for it. The nullable context type exists only to
 * make "used outside the provider" a loud error instead of a confusing undefined.
 */
const MudContext = createContext<SetupResult | null>(null);

type Props = {
  value: SetupResult;
  children: ReactNode;
};

export function MudProvider({ value, children }: Props) {
  return <MudContext.Provider value={value}>{children}</MudContext.Provider>;
}

export function useMud(): SetupResult {
  const value = useContext(MudContext);
  if (!value) throw new Error("useMud must be used inside <MudProvider>");
  return value;
}
