import React, { useEffect, useMemo, useRef, useState } from 'react'
import { format } from 'date-fns'
import { X } from 'lucide-react'

import { Series, dayLabel, fmt } from './data'

const H = 260
const PAD = { top: 16, right: 12, bottom: 28, left: 44 }

export type ChartSeries = { key: string; label: string; color: string; data: Series }

type Props = {
  dates: Date[]
  todayIdx: number
  series: ChartSeries[]
  unitLabel: string
  forecastNote?: string
  onRemove?: (key: string) => void
  footerRight?: React.ReactNode
}

const ACTUAL_SINGLE = 'var(--color-series-1)'
const FORECAST_SINGLE = 'var(--color-accent)'

export function DemandChart({ dates, todayIdx, series, unitLabel, forecastNote, onRemove, footerRight }: Props) {
  const wrap = useRef<HTMLDivElement>(null)
  const [w, setW] = useState(800)
  const [hover, setHover] = useState<number | null>(null)
  const single = series.length === 1
  const band = single ? series[0].data : null
  const showBand = !!(band && band.low && band.high)

  useEffect(() => {
    if (!wrap.current) return
    const ro = new ResizeObserver(([e]) => setW(Math.max(280, e.contentRect.width)))
    ro.observe(wrap.current)
    return () => ro.disconnect()
  }, [])

  const geo = useMemo(() => {
    const all = series.flatMap((s) => [...s.data.actual, ...(s.data.high ?? s.data.forecast)]).filter((v): v is number => v !== null)
    const max = Math.max(1, ...all)
    const step = niceStep(max / 4)
    const yMax = Math.ceil(max / step) * step
    const innerW = w - PAD.left - PAD.right
    const innerH = H - PAD.top - PAD.bottom
    const x = (i: number) => PAD.left + (i / (dates.length - 1)) * innerW
    const y = (v: number) => PAD.top + innerH - (v / yMax) * innerH
    const ticks = Array.from({ length: Math.round(yMax / step) + 1 }, (_, i) => i * step)
    const line = (arr: (number | null)[]) => {
      let d = ''
      let pen = false
      arr.forEach((v, i) => {
        if (v === null) return void (pen = false)
        d += `${pen ? 'L' : 'M'}${x(i)},${y(v)} `
        pen = true
      })
      return d
    }
    const area = (lo: (number | null)[], hi: (number | null)[]) => {
      const idx = hi.map((v, i) => (v === null ? -1 : i)).filter((i) => i >= 0)
      if (!idx.length) return ''
      return `M${idx.map((i) => `${x(i)},${y(hi[i]!)}`).join(' L')} L${[...idx].reverse().map((i) => `${x(i)},${y(lo[i]!)}`).join(' L')} Z`
    }
    const labelEvery = Math.ceil(dates.length / (w < 520 ? 4 : 7))
    return { x, y, ticks, line, area, labelEvery, innerH }
  }, [series, dates, w])

  const onMove = (e: React.MouseEvent<SVGSVGElement>) => {
    const rect = e.currentTarget.getBoundingClientRect()
    const rel = (e.clientX - rect.left - PAD.left) / (w - PAD.left - PAD.right)
    const i = Math.round(rel * (dates.length - 1))
    setHover(i >= 0 && i < dates.length ? i : null)
  }

  const todayX = geo.x(todayIdx)
  const future = hover !== null && hover > todayIdx
  const tipX = hover !== null ? Math.min(Math.max(geo.x(hover) + 12, 0), w - 196) : 0

  return (
    <div>
      <div ref={wrap} className="relative w-full">
        <svg width={w} height={H} className="block select-none" onMouseMove={onMove} onMouseLeave={() => setHover(null)}>
          {geo.ticks.map((t) => (
            <g key={t}>
              <line x1={PAD.left} x2={w - PAD.right} y1={geo.y(t)} y2={geo.y(t)} stroke="var(--color-hairline)" />
              <text x={PAD.left - 8} y={geo.y(t)} dy="0.32em" textAnchor="end" className="fill-muted text-[11px] tabular">
                {fmt(t)}
              </text>
            </g>
          ))}
          {dates.map((d, i) =>
            i % geo.labelEvery === 0 && Math.abs(i - todayIdx) > geo.labelEvery / 2 ? (
              <text key={i} x={geo.x(i)} y={H - 8} textAnchor="middle" className="fill-muted text-[11px]">
                {dayLabel(d)}
              </text>
            ) : null,
          )}

          {showBand && <path d={geo.area(band!.low!, band!.high!)} fill="var(--color-accent)" opacity={0.1} />}

          {series.map((s) => (
            <g key={s.key}>
              <path d={geo.line(s.data.actual)} fill="none" stroke={single ? ACTUAL_SINGLE : s.color} strokeWidth={1.75} strokeLinejoin="round" />
              <path
                d={geo.line(s.data.forecast)}
                fill="none"
                stroke={single ? FORECAST_SINGLE : s.color}
                strokeWidth={2}
                strokeDasharray="5 4"
                strokeLinejoin="round"
              />
            </g>
          ))}

          <line x1={todayX} x2={todayX} y1={PAD.top} y2={PAD.top + geo.innerH} stroke="var(--color-faint)" strokeDasharray="2 3" />
          <text x={todayX} y={H - 8} textAnchor="middle" className="fill-ink text-[11px] font-medium">
            Today
          </text>

          {forecastNote && (
            <text
              x={(todayX + w - PAD.right) / 2}
              y={PAD.top + geo.innerH / 2}
              textAnchor="middle"
              className="fill-muted text-[12px]"
            >
              {forecastNote}
            </text>
          )}

          {hover !== null && (
            <g pointerEvents="none">
              <line x1={geo.x(hover)} x2={geo.x(hover)} y1={PAD.top} y2={PAD.top + geo.innerH} stroke="var(--color-line)" />
              {series.map((s) => {
                const v = future ? s.data.forecast[hover] : s.data.actual[hover]
                if (v === null) return null
                const c = single ? (future ? FORECAST_SINGLE : ACTUAL_SINGLE) : s.color
                return <circle key={s.key} cx={geo.x(hover)} cy={geo.y(v)} r={3.5} fill="white" stroke={c} strokeWidth={2} />
              })}
            </g>
          )}
        </svg>

        {hover !== null && (
          <div
            className="pointer-events-none absolute top-2 w-[184px] rounded-lg border border-line bg-surface px-3 py-2 text-xs shadow-md shadow-ink/5"
            style={{ left: hover > dates.length * 0.6 ? Math.max(geo.x(hover) - 196, 0) : tipX }}
          >
            <p className="text-muted">
              {format(dates[hover], 'EEE, MMM d')} · {future ? 'Forecast' : 'Actual'}
            </p>
            {series.map((s) => {
              const v = future ? s.data.forecast[hover] : s.data.actual[hover]
              const lo = future && single ? s.data.low?.[hover] : null
              const hi = future && single ? s.data.high?.[hover] : null
              return (
                <div key={s.key} className="mt-1">
                  <p className="flex items-center gap-1.5 text-ink tabular">
                    {!single && <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: s.color }} />}
                    {v === null ? (
                      <span className="text-muted">{future ? 'No forecast' : 'No sales recorded'}</span>
                    ) : (
                      <>
                        <span className="font-semibold">{fmt(Math.round(v))}</span> {unitLabel}
                      </>
                    )}
                  </p>
                  {lo != null && hi != null && (
                    <p className="text-muted tabular">
                      Range {fmt(Math.round(lo))}–{fmt(Math.round(hi))}
                    </p>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </div>

      <div className="mt-3 flex flex-wrap items-center justify-between gap-x-6 gap-y-2 sm:pl-11">
        <div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-muted">
          {single ? (
            <>
              <LegendLine color={ACTUAL_SINGLE} label="Actual sales" />
              <LegendLine color={FORECAST_SINGLE} dashed label="Predicted demand" />
              {showBand && (
                <span className="flex items-center gap-2">
                  <span className="h-2.5 w-5 rounded-sm bg-accent/10" /> Likely range
                </span>
              )}
            </>
          ) : (
            <>
              {series.map((s, i) => (
                <span key={s.key} className="flex items-center gap-2 text-body">
                  <span className="h-2 w-2 rounded-full" style={{ background: s.color }} />
                  <span className="max-w-[12rem] truncate">{s.label}</span>
                  {i > 0 && onRemove && (
                    <button onClick={() => onRemove(s.key)} className="rounded p-0.5 text-faint hover:bg-page hover:text-ink" aria-label={`Remove ${s.label}`}>
                      <X className="h-3 w-3" />
                    </button>
                  )}
                </span>
              ))}
              <span className="text-faint">Solid: actual · Dashed: forecast</span>
            </>
          )}
        </div>
        {footerRight}
      </div>
    </div>
  )
}

function LegendLine({ color, label, dashed }: { color: string; label: string; dashed?: boolean }) {
  return (
    <span className="flex items-center gap-2">
      <svg width="20" height="2" aria-hidden>
        <line x1="0" x2="20" y1="1" y2="1" stroke={color} strokeWidth="2" strokeDasharray={dashed ? '5 3' : undefined} />
      </svg>
      {label}
    </span>
  )
}

function niceStep(raw: number) {
  const pow = Math.pow(10, Math.floor(Math.log10(Math.max(raw, 1))))
  const n = raw / pow
  const m = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10
  return m * pow
}
