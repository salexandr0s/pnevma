import React, { createContext, useContext, useMemo } from "react";
import { getTransport, type Transport } from "./transport";

const TransportContext = createContext<Transport | null>(null);

export function TransportProvider({ children }: { children: React.ReactNode }) {
  const transport = useMemo(() => getTransport(), []);
  return (
    <TransportContext.Provider value={transport}>
      {children}
    </TransportContext.Provider>
  );
}

export function useTransport(): Transport {
  const t = useContext(TransportContext);
  if (!t) throw new Error("useTransport must be used within TransportProvider");
  return t;
}
