/*
 * Create the system calls that the client can use to ask
 * for changes in the World state (using the System contracts).
 */

import { ClientComponents } from "./createClientComponents";
import { SetupNetworkResult } from "./setupNetwork";

export type SystemCalls = ReturnType<typeof createSystemCalls>;

export function createSystemCalls(_network: SetupNetworkResult, _components: ClientComponents) {
  // System calls for Atlantysm go here, one per System contract.
  return {};
}
