import React from 'react'

import { Product, UNIT_LABEL, fmt, restockFor } from '../../shared/forecast/data'

type Restock = ReturnType<typeof restockFor>

export function RestockPanel({ product, restock }: { product: Product; restock: Restock }) {
  const unit = UNIT_LABEL[product.unit]
  const cover = restock.available && restock.daily > 0 ? Math.floor(restock.saleable / restock.daily) : null
  const unsaleable = product.unsaleable ?? 0

  return (
    <section className="flex flex-col rounded-xl border border-line bg-surface p-4 sm:p-6">
      <div className={`-mx-1 rounded-lg px-4 py-4 ${restock.available && restock.suggested > 0 ? 'bg-accent-soft' : 'bg-page'}`}>
      <p className="text-sm font-medium text-body">Preliminary suggested restock</p>

      {!restock.available ? (
        <>
          <p className="mt-2 text-xl font-semibold text-ink">No suggestion yet</p>
          <p className="mt-2 text-sm leading-relaxed text-body">
            There isn’t enough sales history to estimate demand for this product, so a restock quantity can’t be suggested.
          </p>
        </>
      ) : restock.suggested > 0 ? (
        <>
          <p className="mt-1 text-5xl font-semibold tracking-tight text-accent-hover tabular">
            {fmt(restock.suggested)} <span className="text-lg font-medium text-body">{unit}</span>
          </p>
          <p className="mt-3 text-sm leading-relaxed text-body">
            About {fmt(restock.demand28)} {unit} are expected to sell over the next 28 days. You have {fmt(restock.saleable)} saleable, so
            roughly {fmt(restock.suggested)} more would cover that period.
          </p>
        </>
      ) : (
        <>
          <p className="mt-2 text-xl font-semibold text-ink">No restock suggested</p>
          <p className="mt-2 text-sm leading-relaxed text-body">
            Your {fmt(restock.saleable)} saleable {unit} should cover the {fmt(restock.demand28)} expected to sell over the next 28 days.
          </p>
        </>
      )}
      </div>

      <dl className="mt-5 divide-y divide-hairline border-t border-hairline text-sm">
        <Row label="Saleable stock" value={`${fmt(restock.saleable)} ${unit}`} hint={unsaleable ? `${fmt(unsaleable)} set aside as damaged` : undefined} />
        <Row label="Expected demand, 28 days" value={restock.available ? `${fmt(restock.demand28)} ${unit}` : '—'} />
        <Row label="Current stock lasts" value={cover === null ? '—' : `About ${cover} days`} />
      </dl>

      <p className="mt-5 text-xs leading-relaxed text-muted lg:mt-auto lg:pt-5">
        Based on LightGBM’s 28-day forecast and saleable stock. Guidance only — nothing is ordered.
      </p>
    </section>
  )
}

function Row({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="flex items-start justify-between gap-4 py-2.5">
      <dt className="text-muted">
        {label}
        {hint && <span className="block text-xs text-faint">{hint}</span>}
      </dt>
      <dd className="text-right text-ink tabular">{value}</dd>
    </div>
  )
}
