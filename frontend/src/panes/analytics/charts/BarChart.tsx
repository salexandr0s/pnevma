type BarData = { label: string; value: number };
type Props = {
  data: BarData[];
  width?: number;
  height?: number;
  barColor?: string;
};

export function BarChart({ data, width = 400, height = 200, barColor = "#34d399" }: Props) {
  if (data.length === 0) return null;
  const maxVal = Math.max(...data.map((d) => d.value), 1);
  const barWidth = Math.max((width - 40) / data.length - 4, 8);
  const chartHeight = height - 30;

  return (
    <svg width={width} height={height} className="overflow-visible">
      {data.map((d, i) => {
        const barH = (d.value / maxVal) * chartHeight;
        const x = 30 + i * (barWidth + 4);
        const y = chartHeight - barH;
        return (
          <g key={i}>
            <rect x={x} y={y} width={barWidth} height={barH} fill={barColor} rx={2} />
            <text x={x + barWidth / 2} y={height - 4} textAnchor="middle" fill="#94a3b8" fontSize={9}>
              {d.label.length > 6 ? d.label.slice(0, 5) + "\u2026" : d.label}
            </text>
          </g>
        );
      })}
      {/* Y-axis labels */}
      <text x={2} y={12} fill="#64748b" fontSize={9}>${maxVal.toFixed(2)}</text>
      <text x={2} y={chartHeight} fill="#64748b" fontSize={9}>$0</text>
    </svg>
  );
}
