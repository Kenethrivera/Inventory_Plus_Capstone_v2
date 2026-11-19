import React, { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { ChevronDown } from 'lucide-react'

import { fmt } from '../../shared/forecast/data'
import { RESTOCK_RECORDS, RestockRecord } from './trackingData'

const COLS = 'sm:grid-cols-4 xl:grid-cols-[minmax(0,2fr)_repeat(4,minmax(0,1fr))_24px]'

export function RestockTracking({ empty, expandedId }: { empty: boolean; expandedId?: string }) {
  const [open, setOpen] = useState<string | null>(expandedId ?? null)
  React.useEffect(() => setOpen(expandedId ?? null), [expandedId])

  if (empty) {
    return (
      <div className="rounded-xl border border-dashed border-line bg-surface px-6 py-14 text-center">
        <p className="text-base font-semibold text-ink">No restock records yet</p>
        <p className="mx-auto mt-1.5 max-w-md text-sm text-muted">Records appear here once a recommendation is saved.</p>
      </div>
    )
  }

  return (
    <section className="rounded-xl border border-line bg-surface">
      <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-2 px-4 pb-4 pt-5 sm:px-6">
        <p className="max-w-xl text-sm text-body">
          Compare what Inventory Plus predicted and suggested with what the store actually added to inventory.
        </p>
        <span className="shrink-0 rounded border border-line bg-page px-1.5 py-0.5 text-xs font-medium text-body">Demo data</span>
      </div>

      <div className={`hidden gap-4 border-y border-hairline bg-page/60 px-6 py-2 text-xs font-medium text-muted xl:grid ${COLS}`}>
        <span>Date and product</span>
        <span className="text-right">Forecasted demand</span>
        <span className="text-right">Recommended restock</span>
        <span className="text-right">Actual restock</span>
        <span className="text-right">Difference</span>
        <span />
      </div>

      <ul className="divide-y divide-hairline border-t border-hairline xl:border-t-0">
        {RESTOCK_RECORDS.map((r) => (
          <Row key={r.id} r={r} open={open === r.id} onToggle={() => setOpen((o) => (o === r.id ? null : r.id))} />
        ))}
      </ul>

      <p className="border-t border-hairline px-4 py-3 text-xs text-muted sm:px-6">
        Difference = actual restock − recommended restock. Forecasted demand covers the 28 days after each date.
      </p>
    </section>
  )
}

function Row({ r, open, onToggle }: { r: RestockRecord; open: boolean; onToggle: () => void }) {
  const diff = r.actual === null ? null : r.actual - r.recommended
  const qty = (n: number) => (
    <>
      {fmt(n)} <span className="text-xs text-muted">{r.unit}</span>
    </>
  )

  return (
    <li>
      <button
        onClick={onToggle}
        aria-expanded={open}
        className={`grid w-full grid-cols-2 gap-x-4 gap-y-2 px-4 py-3 text-left text-sm transition-colors duration-150 hover:bg-page/60 xl:items-center xl:px-6 ${COLS}`}
      >
        <span className="col-span-2 flex min-w-0 items-baseline justify-between gap-3 sm:col-span-4 xl:col-span-1 xl:block">
          <span className="min-w-0">
            <span className="block text-xs text-muted">{r.date}</span>
            <span className="block truncate font-medium text-ink">{r.product}</span>
          </span>
          <ChevronDown className={`h-4 w-4 shrink-0 text-muted transition-transform duration-200 xl:hidden ${open ? 'rotate-180' : ''}`} />
        </span>
        <Cell label="Forecasted demand">{qty(r.forecast)}</Cell>
        <Cell label="Recommended restock">{qty(r.recommended)}</Cell>
        <Cell label="Actual restock">{r.actual === null ? <span className="text-muted">No recorded match</span> : qty(r.actual)}</Cell>
        <Cell label="Difference">
          {diff === null ? (
            <span className="text-faint">—</span>
          ) : (
            <>
              {diff === 0 ? '0' : `${diff > 0 ? '+' : '−'}${fmt(Math.abs(diff))}`} <span className="text-xs text-muted">{r.unit}</span>
            </>
          )}
        </Cell>
        <ChevronDown className={`hidden h-4 w-4 justify-self-end text-muted transition-transform duration-200 xl:block ${open ? 'rotate-180' : ''}`} />
      </button>

      <AnimatePresence initial={false}>
        {open && (
          <motion.div
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.2, ease: [0.23, 1, 0.32, 1] }}
            className="overflow-hidden"
          >
            <dl className="grid gap-x-8 gap-y-2 bg-page/60 px-4 py-3 text-sm sm:grid-cols-2 xl:px-6 lg:grid-cols-4">
              <Detail label="Forecast period" value={r.period} />
              <Detail label="Forecast method" value="LightGBM (preliminary)" />
              <Detail label="Saleable stock at the time" value={`${fmt(r.saleableThen)} ${r.unit}`} />
              <Detail
                label="Stock added"
                value={r.additions.length ? r.additions.map((a) => `${a.date}: ${fmt(a.qty)} ${r.unit}`).join(' · ') : 'None recorded yet'}
              />
            </dl>
          </motion.div>
        )}
      </AnimatePresence>
    </li>
  )
}

function Cell({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <span className="min-w-0 xl:text-right">
      <span className="block text-xs text-muted xl:hidden">{label}</span>
      <span className="text-ink tabular">{children}</span>
    </span>
  )
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="text-ink">{value}</dd>
    </div>
  )
}
