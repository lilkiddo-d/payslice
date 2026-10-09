export interface Slice {
  label: string;
  value: number;
  color: string;
}

export const PALETTE = ["#19c39c", "#7c5cff", "#ffb547", "#4cc3ff", "#ff5c7a", "#c58bff"];

/** Simple SVG donut chart. */
export function Pie({ slices, size = 180 }: { slices: Slice[]; size?: number }) {
  const total = slices.reduce((a, s) => a + s.value, 0) || 1;
  const r = size / 2 - 10;
  const c = size / 2;
  let angle = -Math.PI / 2;
  const paths = slices
    .filter((s) => s.value > 0)
    .map((s) => {
      const frac = s.value / total;
      if (frac >= 0.9999) return <circle key={s.label} cx={c} cy={c} r={r} fill={s.color} />;
      const a0 = angle;
      const a1 = angle + frac * 2 * Math.PI;
      angle = a1;
      const large = a1 - a0 > Math.PI ? 1 : 0;
      const d = `M ${c} ${c} L ${c + r * Math.cos(a0)} ${c + r * Math.sin(a0)} A ${r} ${r} 0 ${large} 1 ${c + r * Math.cos(a1)} ${c + r * Math.sin(a1)} Z`;
      return <path key={s.label} d={d} fill={s.color} />;
    });
  return (
    <div className="row" style={{ gap: 20 }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} role="img" aria-label="Pay split">
        {paths}
        <circle cx={c} cy={c} r={r * 0.55} fill="var(--panel)" />
      </svg>
      <div className="legend">
        {slices.map((s) => (
          <div key={s.label}>
            <span className="sw" style={{ background: s.color }} />
            {s.label} — {((s.value / total) * 100).toFixed(1)}%
          </div>
        ))}
      </div>
    </div>
  );
}
