import React, { useEffect, useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { AlertTriangle } from 'lucide-react'
import { addDays } from 'date-fns'

import { Product, TODAY, dayLabel } from '../../shared/forecast/data'

const VISIBLE = [
  'Predictions are estimates, not guaranteed sales.',
  'Stockouts may cause recorded sales to understate true demand.',
]
const MORE = [
  'Promotions, local projects, or price changes may affect future demand.',
  'Forecast reliability depends on available and accurate sales history.',
]

export function ForecastContext({ product, limitationsExpanded = false }: { product: Product; limitationsExpanded?: boolean }) {
  const [open, setOpen] = useState(limitationsExpanded)
  useEffect(() => setOpen(limitationsExpanded), [limitationsExpanded])

  const days = product.historyDays
  const history =
    days === 0 ? 'No sales recorded' : days !== undefined ? `${days} days, from ${dayLabel(addDays(TODAY, -days + 1))}` : '56 days in view'
  const quality =
    days === 0
      ? 'Nothing to assess yet'
      : product.forecastUnavailable
        ? 'Too few sales for daily forecast'
        : days !== undefined
          ? 'Short history'
          : 'No missing days in this period'

  return (
    <div className="grid items-start gap-6 md:grid-cols-2">
      <section className="rounded-xl border border-line border-l-4 border-l-caution bg-caution-soft px-4 py-4 sm:px-5">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-caution-ink">
          <AlertTriangle className="h-4 w-4 shrink-0 text-caution" />
          Important Forecast Limitations
        </h2>
        <ul className="mt-2 space-y-1 pl-6 text-sm leading-relaxed text-ink">
          {VISIBLE.map((l) => (
            <li key={l} className="list-disc marker:text-caution">
              {l}
            </li>
          ))}
        </ul>
        <AnimatePresence initial={false}>
          {open && (
            <motion.ul
              initial={{ height: 0, opacity: 0 }}
              animate={{ height: 'auto', opacity: 1 }}
              exit={{ height: 0, opacity: 0 }}
              transition={{ duration: 0.2, ease: [0.23, 1, 0.32, 1] }}
              className="overflow-hidden pl-6 text-sm leading-relaxed text-ink"
            >
              {MORE.map((l) => (
                <li key={l} className="list-disc pt-1 marker:text-caution">
                  {l}
                </li>
              ))}
            </motion.ul>
          )}
        </AnimatePresence>
        {MORE.length > 0 && (
          <button
            onClick={() => setOpen((o) => !o)}
            aria-expanded={open}
            className="mt-2 pl-6 text-sm font-medium text-caution-ink underline-offset-2 hover:underline"
          >
            {open ? 'Show less' : `Read all limitations (${VISIBLE.length + MORE.length})`}
          </button>
        )}
      </section>

      <section className="rounded-xl border border-line bg-surface px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold text-ink">About this forecast</h2>
        <dl className="mt-1 divide-y divide-hairline text-sm">
          <Row label="Sales history" value={history} />
          <Row label="Data quality" value={quality} />
          <Row label="Seasonal pattern" value="Not classified yet" />
        </dl>
        <p className="mt-1.5 text-xs text-faint">Simulation/demo data</p>
      </section>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-4 py-2">
      <dt className="shrink-0 text-muted">{label}</dt>
      <dd className="min-w-0 truncate text-right text-ink">{value}</dd>
    </div>
  )
}
