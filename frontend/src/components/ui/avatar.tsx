interface AvatarProps {
  name: string;
  size?: "sm" | "md" | "lg";
  className?: string;
}

const sizeClasses = {
  sm: "h-6 w-6 text-[10px]",
  md: "h-8 w-8 text-xs",
  lg: "h-10 w-10 text-sm",
};

function hashHue(name: string): number {
  let sum = 0;
  for (let i = 0; i < name.length; i++) {
    sum += name.charCodeAt(i);
  }
  return sum % 360;
}

function getInitials(name: string): string {
  const parts = name.split(/[\s\-_/]+/).filter(Boolean);
  if (parts.length >= 2) {
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
  return name.slice(0, 2).toUpperCase();
}

export function Avatar({ name, size = "md", className = "" }: AvatarProps) {
  const hue = hashHue(name);
  return (
    <span
      className={`inline-flex shrink-0 items-center justify-center rounded-full font-semibold ${sizeClasses[size]} ${className}`}
      style={{
        backgroundColor: `hsl(${hue}, 50%, 25%)`,
        color: `hsl(${hue}, 70%, 75%)`,
      }}
      title={name}
    >
      {getInitials(name)}
    </span>
  );
}
