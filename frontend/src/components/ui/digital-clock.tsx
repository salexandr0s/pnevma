import { useEffect, useState } from "react";

function formatTime(): string {
  const now = new Date();
  return now.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

export function DigitalClock({ className = "" }: { className?: string }) {
  const [time, setTime] = useState(formatTime);

  useEffect(() => {
    const id = setInterval(() => setTime(formatTime()), 10_000);
    return () => clearInterval(id);
  }, []);

  return (
    <span className={`clock-display text-xs text-slate-300 ${className}`}>
      {time}
    </span>
  );
}
