import { useCallback, useState } from "react";

import { readableError, useToast } from "../components/Toaster";

/**
 * One in-flight write at a time, with the outcome reported as a toast.
 *
 * Serialising is deliberate: the burner wallet has a single nonce, and two buttons fired together
 * would produce a confusing "nonce too low" rather than two results. `pending` carries the key of
 * the action running, so a panel can disable exactly the button that is busy and grey out the rest.
 */
export function useAction() {
  const [pending, setPending] = useState<string | null>(null);
  const toast = useToast();

  const run = useCallback(
    async (key: string, successMessage: string, action: () => Promise<unknown>) => {
      if (pending) return;
      setPending(key);
      try {
        await action();
        toast.success(successMessage);
      } catch (error) {
        toast.error(readableError(error));
      } finally {
        setPending(null);
      }
    },
    [pending, toast],
  );

  return { pending, busy: pending !== null, run };
}
