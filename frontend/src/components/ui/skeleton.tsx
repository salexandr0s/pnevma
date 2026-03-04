interface SkeletonProps {
  className?: string;
}

export function Skeleton({ className = "" }: SkeletonProps) {
  return <div className={`skeleton h-4 w-full ${className}`} />;
}

interface SkeletonTextProps {
  lines?: number;
  className?: string;
}

export function SkeletonText({ lines = 3, className = "" }: SkeletonTextProps) {
  const widths = ["w-full", "w-[85%]", "w-[70%]"];
  return (
    <div className={`space-y-2 ${className}`}>
      {Array.from({ length: lines }, (_, i) => (
        <div
          key={i}
          className={`skeleton h-3 ${widths[i % widths.length]}`}
        />
      ))}
    </div>
  );
}

export function SkeletonCard({ className = "" }: SkeletonProps) {
  return (
    <div
      className={`rounded-lg border border-white/10 bg-slate-950/70 p-3 space-y-2 ${className}`}
    >
      <div className="skeleton h-4 w-3/4" />
      <div className="skeleton h-3 w-full" />
      <div className="skeleton h-3 w-[85%]" />
      <div className="flex items-center gap-2 pt-1">
        <div className="skeleton h-6 w-6 rounded-full" />
        <div className="skeleton h-3 w-20" />
      </div>
    </div>
  );
}
