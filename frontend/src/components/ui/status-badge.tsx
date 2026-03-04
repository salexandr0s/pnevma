import type { ReactNode } from "react";

export type BadgeVariant =
  | "success"
  | "warning"
  | "error"
  | "info"
  | "neutral"
  | "mint";

interface StatusBadgeProps {
  variant: BadgeVariant;
  children: ReactNode;
  dot?: boolean;
  className?: string;
}

const dotColors: Record<BadgeVariant, string> = {
  success: "bg-green-400",
  warning: "bg-amber-400",
  error: "bg-red-400",
  info: "bg-sky-400",
  neutral: "bg-slate-400",
  mint: "bg-mint-400",
};

export function StatusBadge({
  variant,
  children,
  dot,
  className = "",
}: StatusBadgeProps) {
  return (
    <span className={`badge badge-${variant} ${className}`}>
      {dot && (
        <span
          className={`inline-block h-1.5 w-1.5 rounded-full ${dotColors[variant]}`}
        />
      )}
      {children}
    </span>
  );
}

export function taskStatusVariant(status: string): BadgeVariant {
  switch (status) {
    case "Done":
    case "Merged":
      return "success";
    case "InProgress":
    case "Running":
      return "mint";
    case "Ready":
    case "Pending":
    case "Queued":
      return "info";
    case "Blocked":
    case "Failed":
      return "error";
    case "Review":
      return "warning";
    default:
      return "neutral";
  }
}

export function notificationLevelVariant(level: string): BadgeVariant {
  switch (level) {
    case "critical":
    case "error":
      return "error";
    case "warning":
      return "warning";
    case "success":
      return "success";
    case "info":
      return "info";
    default:
      return "neutral";
  }
}

export function mergeQueueStatusVariant(status: string): BadgeVariant {
  switch (status) {
    case "merged":
      return "success";
    case "queued":
      return "info";
    case "running":
      return "mint";
    case "failed":
      return "error";
    default:
      return "neutral";
  }
}
