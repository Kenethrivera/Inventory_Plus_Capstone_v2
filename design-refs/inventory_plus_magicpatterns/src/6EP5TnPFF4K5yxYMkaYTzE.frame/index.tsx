import React, { useEffect, useMemo, useState } from 'react'

import { AppShell } from '../shared/forecast/AppShell'
import { ForecastingHeader, ForecastTab } from '../shared/forecast/ForecastingHeader'
import { ForecastChart } from '../shared/forecast/ForecastChart'
import { ForecastMethod } from '../shared/forecast/Controls'
import { ModelId, PRODUCTS, UNIT_LABEL, buildSeries, fmt, restockFor, timeline } from '../shared/forecast/data'
import { ProductPicker } from './components/ProductPicker'
import { RestockPanel } from './components/RestockPanel'
import { ForecastContext } from './components/ForecastContext'

export const args = {
  productId: 'p1',
  model: 'blend',
  horizon: '28',
  limitationsExpanded: false,
}

export const argTypes = {
  productId: {
    control: 'select',
    options: ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8', 'p9', 'p10', 'p11', 'p12', 'p13', 'p14'],
  },
  model: { control: 'select', options: ['blend', 'lightgbm', 'mean28', 'seasonal'] },
  horizon: { control: 'radio', options: ['7', '28'] },
  limitationsExpanded: { control: 'boolean' },
}

type Props = Partial<typeof args> & {
  onProductChange?: (id: string) => void
  onModelChange?: (m: string) => void
  onHorizonChange?: (h: string) => void
  onTabChange?: (t: ForecastTab) => void
  onViewAccuracy?: () => void
}

export default function ProductForecast(props: Props) {
  const p = { ...args, ...props }
  const [productId, setProductId] = useState(p.productId)
  const [model, setModel] = useState(p.model)
  const [horizon, setHorizon] = useState(p.horizon)

  useEffect(() => setProductId(p.productId), [p.productId])
  useEffect(() => setModel(p.model), [p.model])
  useEffect(() => setHorizon(p.horizon), [p.horizon])

  const product = PRODUCTS.find((x) => x.id === productId) ?? PRODUCTS[0]
  const unit = UNIT_LABEL[product.unit]
  const restock = useMemo(() => restockFor(product), [product])

  // Period totals follow the chart's forecast method.
  const periods = useMemo(() => {
    const s = buildSeries([product], 28, model as ModelId)
    const t = timeline(28).todayIdx
    const sum = (arr: (number | null)[] | null, n: number) =>
      arr ? Math.round(arr.slice(t + 1, t + 1 + n).reduce<number>((a, b) => a + (b ?? 0), 0)) : null
    const ok = !s.noHistory && !s.forecastUnavailable
    return {
      ok,
      today: ok && s.today !== null ? Math.round(s.today) : null,
      d7: ok ? sum(s.forecast, 7) : null,
      d7lo: ok ? sum(s.low, 7) : null,
      d7hi: ok ? sum(s.high, 7) : null,
      d28: ok ? sum(s.forecast, 28) : null,
      d28lo: ok ? sum(s.low, 28) : null,
      d28hi: ok ? sum(s.high, 28) : null,
    }
  }, [product, model])

  const selectProduct = (id: string) => {
    setProductId(id)
    p.onProductChange?.(id)
  }
  const changeHorizon = (h: string) => {
    setHorizon(h)
    p.onHorizonChange?.(h)
  }
  const changeModel = (m: ModelId) => {
    setModel(m)
    p.onModelChange?.(m)
  }

  return (
    <AppShell>
      <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
        <ForecastingHeader active="product" onTabChange={p.onTabChange} />

        {/* Product */}
        <div className="mt-6">
          <ProductPicker value={product.id} onChange={selectProduct} />
          <p className="mt-1.5 flex flex-wrap gap-x-2 gap-y-1 text-sm text-muted">
            <span>{product.category}</span>
            <span className="text-faint">·</span>
            <span>{product.sku}</span>
            <span className="text-faint">·</span>
            <span>Sold in {unit}</span>
            <span className="text-faint">·</span>
            <span className="text-ink">
              <span className="font-semibold tabular">{fmt(product.onHand)}</span> {unit} in stock
            </span>
          </p>
        </div>

        <div className="mt-6 grid gap-6 lg:grid-cols-3">
          {/* Forecast */}
          <section className="min-w-0 rounded-xl border border-line bg-surface lg:col-span-2">
            <div className="grid divide-y divide-hairline border-b sm:grid-cols-3 sm:divide-x sm:divide-y-0 border-hairline">
              <PeriodCell label="Today" value={periods.today} unit={unit} />
              <PeriodCell
                label="Short-term (7 days)"
                value={periods.d7}
                lo={periods.d7lo}
                hi={periods.d7hi}
                unit={unit}
                selected={horizon === '7'}
                onClick={() => changeHorizon('7')}
              />
              <PeriodCell
                label="Planning (28 days)"
                value={periods.d28}
                lo={periods.d28lo}
                hi={periods.d28hi}
                unit={unit}
                selected={horizon === '28'}
                onClick={() => changeHorizon('28')}
              />
            </div>

            <div className="p-4 sm:p-6">
              <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
                <h2 className="text-sm font-medium text-ink">
                  Daily sales and forecast <span className="font-normal text-muted">· {horizon === '7' ? 'next 7 days shown' : 'next 28 days shown'}</span>
                </h2>
                <div className="-mr-1.5">
                  <ForecastMethod value={model as ModelId} onChange={changeModel} />
                </div>
              </div>
              <ForecastChart
                embedded
                lockedScope={{ kind: 'product', id: product.id }}
                model={model as ModelId}
                horizon={horizon}
                onModelChange={changeModel}
                onHorizonChange={changeHorizon}
                onViewAccuracy={p.onViewAccuracy}
              />
            </div>
          </section>

          {/* Restock */}
          <RestockPanel product={product} restock={restock} />
        </div>

        <div className="mt-6">
          <ForecastContext product={product} limitationsExpanded={p.limitationsExpanded} />
        </div>

        <p className="mt-8 text-xs text-faint">Example products and simulated sales for demonstration only.</p>
      </div>
    </AppShell>
  )
}

function PeriodCell({
  label,
  value,
  lo,
  hi,
  unit,
  selected,
  onClick,
}: {
  label: string
  value: number | null
  lo?: number | null
  hi?: number | null
  unit: string
  selected?: boolean
  onClick?: () => void
}) {
  const inner = (
    <>
      <span className="block truncate text-xs text-muted sm:text-sm">{label}</span>
      <span className="mt-1 block text-xl font-semibold tracking-tight text-ink tabular sm:text-2xl">
        {value === null ? '—' : fmt(value)} {value !== null && <span className="text-sm font-medium text-muted">{unit}</span>}
      </span>
      <span className="mt-0.5 block h-4 truncate text-xs text-muted tabular">
        {lo != null && hi != null ? `Likely ${fmt(lo)}–${fmt(hi)}` : label === 'Today' && value !== null ? 'Estimated' : ''}
      </span>
    </>
  )
  const base = 'relative min-w-0 px-3 py-4 text-left sm:px-6 sm:py-5'
  if (!onClick) return <div className={base}>{inner}</div>
  return (
    <button
      onClick={onClick}
      aria-pressed={selected}
      className={`${base} transition-colors duration-150 hover:bg-page/60 ${selected ? 'bg-page/40' : ''}`}
    >
      {inner}
      <span className={`absolute inset-x-0 bottom-0 h-0.5 ${selected ? 'bg-accent' : 'bg-transparent'}`} />
    </button>
  )
}
