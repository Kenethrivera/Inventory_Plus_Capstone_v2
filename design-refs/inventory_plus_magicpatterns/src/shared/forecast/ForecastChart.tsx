import React, { useEffect, useMemo, useState } from 'react'
import { ArrowRight, Info } from 'lucide-react'

import { DemandChart, ChartSeries } from './DemandChart'
import { CategoryUnitToggle, CompareAdd, ForecastMethod, HorizonToggle, ScopeSelect, horizonDescription, horizonLabel } from './Controls'
import { DEFAULT_SCOPE, ModelId, Scope, UNIT_LABEL, buildSeries, dayLabel, fmt, resolveScope, scopeKey, summarize, timeline } from './data'

export type ChartState = 'default' | 'loading' | 'no-history' | 'forecast-unavailable' | 'incomplete-history' | 'no-compatible'

const DEMO_SCOPE: Partial<Record<ChartState, Scope>> = {
  'no-history': { kind: 'product', id: 'p13' },
  'forecast-unavailable': { kind: 'product', id: 'p14' },
  'incomplete-history': { kind: 'product', id: 'p12' },
  'no-compatible': { kind: 'unit', unit: 'qt' },
}

const COLORS = ['var(--color-series-1)', 'var(--color-series-2)', 'var(--color-series-3)']

type Props = {
  model: ModelId
  horizon: string
  onModelChange: (m: ModelId) => void
  onHorizonChange: (h: string) => void
  initialScope?: Scope
  /** Fixes the chart to one scope (product page) and hides scope + compare controls */
  lockedScope?: Scope
  state?: ChartState
  onViewAccuracy?: () => void
  /** Draw only the chart body: the parent supplies the card, controls and headline */
  embedded?: boolean
}

export function ForecastChart({ model, horizon, onModelChange, onHorizonChange, initialScope, lockedScope, state = 'default', onViewAccuracy, embedded = false }: Props) {
  const [scope, setScope] = useState<Scope>(lockedScope ?? DEMO_SCOPE[state] ?? initialScope ?? DEFAULT_SCOPE)
  const [compare, setCompare] = useState<Scope[]>([])

  useEffect(() => {
    const s = lockedScope ?? DEMO_SCOPE[state]
    if (s) setScope(s)
    setCompare([])
  }, [state, lockedScope && scopeKey(lockedScope)])

  const days = Number(horizon)
  const { dates, todayIdx } = timeline(days)
  const primary = resolveScope(scope)
  const unit = UNIT_LABEL[primary.unit]

  const series: ChartSeries[] = useMemo(
    () =>
      [scope, ...compare].map((s, i) => {
        const r = resolveScope(s)
        return { key: scopeKey(s), label: r.short, color: COLORS[i], data: buildSeries(r.products, days, model) }
      }),
    [scope, compare, days, model],
  )
  const main = series[0].data
  const sum = summarize(main, todayIdx, days)
  const comparing = series.length > 1

  const changeScope = (s: Scope) => {
    setScope(s)
    const u = resolveScope(s).unit
    setCompare((c) => c.filter((x) => resolveScope(x).unit === u && scopeKey(x) !== scopeKey(s)))
  }

  const body: 'loading' | 'no-compatible' | 'no-history' | 'chart' =
    state === 'loading' ? 'loading' : primary.products.length === 0 ? 'no-compatible' : main.noHistory && !comparing ? 'no-history' : 'chart'

  return (
    <section className={embedded ? '' : 'rounded-xl border border-line bg-surface p-4 sm:p-6'}>
      {!embedded && (
      <>
      {/* Controls */}
      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        {lockedScope ? (
          <h2 className="text-base font-semibold text-ink">Demand</h2>
        ) : (
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <ScopeSelect value={scope} onChange={changeScope} />
            {scope.kind === 'category' && (
              <CategoryUnitToggle category={scope.category} unit={scope.unit} onChange={(u) => changeScope({ ...scope, unit: u })} />
            )}
            {body === 'chart' && series.length < 3 && (
              <CompareAdd unit={primary.unit} exclude={series.map((s) => s.key)} onAdd={(s) => setCompare((c) => [...c, s])} />
            )}
          </div>
        )}
        <HorizonToggle value={horizon} onChange={onHorizonChange} />
      </div>

      {/* Headline */}
      <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div className="min-w-0">
          {body === 'chart' && !comparing && !main.forecastUnavailable && (
            <>
              <p className="text-sm text-muted">
                Expected demand · {horizonLabel(horizon)} <span className="text-faint">· {horizonDescription(horizon)}</span>
              </p>
              <div className="mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-1">
                <p className="text-4xl font-semibold tracking-tight text-ink tabular">
                  {fmt(sum.forecast)} <span className="text-lg font-medium text-muted">{unit}</span>
                </p>
                <p className="text-sm text-body tabular">
                  {sum.change !== null && (
                    <>
                      {sum.change >= 0 ? '+' : '−'}
                      {Math.abs(Math.round(sum.change * 100))}% vs previous {days} days
                    </>
                  )}
                  {sum.low !== null && sum.high !== null && (
                    <span className="text-muted">
                      {sum.change !== null && ' · '}likely {fmt(sum.low)}–{fmt(sum.high)}
                    </span>
                  )}
                </p>
              </div>
            </>
          )}
          {body === 'chart' && !comparing && main.forecastUnavailable && (
            <>
              <p className="text-sm text-muted">{horizonLabel(horizon)}</p>
              <p className="mt-1 text-xl font-semibold text-ink">Forecast unavailable</p>
              <p className="mt-0.5 text-sm text-muted">Sales are too infrequent to estimate daily demand. Recorded sales are shown below.</p>
            </>
          )}
          {body === 'chart' && comparing && (
            <p className="text-sm text-muted">
              Comparing {series.length} series in {unit} · {horizonLabel(horizon)}
            </p>
          )}
          {body === 'loading' && (
            <div className="space-y-2">
              <div className="h-4 w-48 animate-pulse rounded bg-page" />
              <div className="h-9 w-40 animate-pulse rounded bg-page" />
            </div>
          )}
        </div>
        {body !== 'no-compatible' && body !== 'no-history' && (
          <div className="shrink-0 sm:-mr-1.5">
            <ForecastMethod value={model} onChange={onModelChange} />
          </div>
        )}
      </div>
      </>
      )}

      {body === 'chart' && main.historyStart && !comparing && (
        <p className={`flex items-start gap-2 text-sm text-body ${embedded ? '' : 'mt-3'}`}>
          <Info className="mt-0.5 h-4 w-4 shrink-0 text-muted" />
          Sales history is incomplete — records start {dayLabel(main.historyStart)}. Treat this forecast as a rough guide.
        </p>
      )}

      {/* Body */}
      <div className={embedded && !(main.historyStart && !comparing) ? '' : 'mt-5'}>
        {body === 'chart' && (
          <DemandChart
            dates={dates}
            todayIdx={todayIdx}
            series={series}
            unitLabel={unit}
            forecastNote={!comparing && main.forecastUnavailable ? 'No forecast available' : undefined}
            onRemove={(k) => setCompare((c) => c.filter((s) => scopeKey(s) !== k))}
            footerRight={<FooterLinks onViewAccuracy={onViewAccuracy} />}
          />
        )}
        {body === 'loading' && (
          <div className="flex h-[260px] items-center justify-center rounded-lg bg-page/70">
            <p className="text-sm text-muted">Loading sales history…</p>
          </div>
        )}
        {body === 'no-history' && (
          <Empty
            title="No recorded sales yet"
            text={`${primary.label} has stock on hand but no sales on record, so there’s nothing to chart or forecast. A forecast appears once sales are recorded.`}
          />
        )}
        {body === 'no-compatible' && (
          <Empty
            title={`No products are measured in ${unit}`}
            text="Choose another unit, category or product to see demand."
            action={
              <button onClick={() => changeScope(DEFAULT_SCOPE)} className="mt-4 text-sm font-medium text-accent hover:text-accent-hover">
                Show all pcs
              </button>
            }
          />
        )}
      </div>
    </section>
  )
}

function FooterLinks({ onViewAccuracy }: { onViewAccuracy?: () => void }) {
  return (
    <div className="flex items-center gap-4 text-xs">
      <span className="text-faint">Simulated sales data</span>
      <button onClick={onViewAccuracy} className="group inline-flex items-center gap-1 font-medium text-muted hover:text-accent">
        View forecast accuracy
        <ArrowRight className="h-3.5 w-3.5 transition-transform duration-150 group-hover:translate-x-0.5" />
      </button>
    </div>
  )
}

function Empty({ title, text, action }: { title: string; text: string; action?: React.ReactNode }) {
  return (
    <div className="flex min-h-[220px] flex-col items-center justify-center rounded-lg border border-dashed border-line px-6 py-10 text-center">
      <p className="text-base font-medium text-ink">{title}</p>
      <p className="mt-1 max-w-md text-sm text-muted">{text}</p>
      {action}
    </div>
  )
}
