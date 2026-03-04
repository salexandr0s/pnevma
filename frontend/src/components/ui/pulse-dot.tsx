type PulseDotVariant = "live" | "idle" | "error" | "warning";

interface PulseDotProps {
  variant?: PulseDotVariant;
  className?: string;
}

const variantClasses: Record<PulseDotVariant, string> = {
  live: "bg-mint-400 animate-pulse-dot",
  idle: "bg-slate-500",
  error: "bg-red-400 animate-pulse",
  warning: "bg-amber-400 animate-pulse-dot",
};

export function PulseDot({ variant = "idle", className = "" }: PulseDotProps) {
  return (
    <span
      className={`inline-block h-2 w-2 rounded-full ${variantClasses[variant]} ${className}`}
      aria-hidden="true"
    />
  );
}
