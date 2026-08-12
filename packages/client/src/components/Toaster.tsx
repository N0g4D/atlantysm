import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";

type ToastKind = "success" | "error";

type Toast = {
  id: number;
  kind: ToastKind;
  message: string;
};

type ToastApi = {
  success: (message: string) => void;
  error: (message: string) => void;
};

const ToastContext = createContext<ToastApi | null>(null);

const DURATION_MS = 5000;

/**
 * Twelve lines instead of a dependency. Toasts here carry one sentence and disappear; anything that
 * needs an action or a history belongs in the panel that caused it, not in a floating layer.
 */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const push = useCallback((kind: ToastKind, message: string) => {
    const id = Date.now() + Math.random();
    setToasts((current) => [...current, { id, kind, message }]);
    setTimeout(() => setToasts((current) => current.filter((t) => t.id !== id)), DURATION_MS);
  }, []);

  const api = useMemo<ToastApi>(
    () => ({
      success: (message) => push("success", message),
      error: (message) => push("error", message),
    }),
    [push],
  );

  return (
    <ToastContext.Provider value={api}>
      {children}

      <div className="pointer-events-none fixed bottom-6 left-1/2 z-50 flex w-full max-w-md -translate-x-1/2 flex-col gap-2 px-6">
        {toasts.map((toast) => (
          <div
            key={toast.id}
            role="status"
            className={`panel-flat pointer-events-auto px-4 py-3 text-sm shadow-line ${
              toast.kind === "success" ? "bg-solarpunk-mint" : "bg-solarpunk-peach"
            }`}
          >
            {toast.message}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastApi {
  const api = useContext(ToastContext);
  if (!api) throw new Error("useToast must be used inside <ToastProvider>");
  return api;
}

/**
 * Wallet and node errors arrive as multi-paragraph dumps with stack traces. The first line is
 * almost always the useful part, and a decoded custom error name — which MUD's Systems all use —
 * lands there.
 */
export function readableError(error: unknown): string {
  if (error instanceof Error) {
    const firstLine = error.message.split("\n").find((line) => line.trim().length > 0);
    return (firstLine ?? error.message).slice(0, 160);
  }
  return String(error).slice(0, 160);
}
