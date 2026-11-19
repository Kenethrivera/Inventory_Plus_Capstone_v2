import React from 'react'
import { ChevronRight } from 'lucide-react'

import { RESTOCK, UNIT_LABEL, fmt } from './data'

export function RestockTable({ onOpenProduct }: { onOpenProduct?: (id: string) => void }) {
  return (
    <section className="h-full rounded-xl border border-line bg-surface">
      <div className="flex items-center justify-between gap-3 px-4 pb-3 pt-4 sm:px-6 sm:pt-5">
        <h2 className="text-base font-semibold text-ink">Restock priorities</h2>
        <a href="#" onClick={(e) => e.preventDefault()} className="whitespace-nowrap text-sm font-medium text-muted hover:text-ink">
          View all recommendations
        </a>
      </div>

      <div className="hidden grid-cols-[minmax(0,1fr)_88px_128px_112px] gap-4 border-y border-hairline bg-page/60 px-6 py-2 text-xs font-medium text-muted sm:grid">
        <span>Product</span>
        <span className="text-right">On hand</span>
        <span className="whitespace-nowrap text-right">Suggested restock</span>
        <span className="text-right">Action</span>
      </div>

      <ul className="divide-y divide-hairline border-t border-hairline sm:border-t-0">
        {RESTOCK.map((p) => {
          const unit = UNIT_LABEL[p.unit]
          return (
            <li
              key={p.id}
              className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-2 px-4 py-3.5 sm:grid-cols-[minmax(0,1fr)_88px_128px_112px] sm:px-6"
            >
              <button onClick={() => onOpenProduct?.(p.id)} className="group col-span-2 min-w-0 text-left sm:col-span-1">
                <span className="flex items-center gap-1 text-sm font-medium text-ink group-hover:text-accent">
                  <span className="truncate">{p.name}</span>
                  <ChevronRight className="h-3.5 w-3.5 shrink-0 text-faint transition-transform duration-150 group-hover:translate-x-0.5 group-hover:text-accent" />
                </span>
                <span className="mt-0.5 block truncate text-xs text-muted">{p.reason}</span>
              </button>

              <div className="flex items-baseline gap-4 sm:contents">
                <p className="text-sm text-body tabular sm:text-right">
                  <span className="text-muted sm:hidden">On hand </span>
                  {fmt(p.onHand)}
                  <span className="text-xs text-muted"> {unit}</span>
                </p>
                <p className="text-sm tabular sm:text-right">
                  <span className="text-muted sm:hidden">Suggested restock </span>
                  <span className="text-base font-semibold text-ink">{fmt(p.suggested)}</span>
                  <span className="text-xs text-muted"> {unit}</span>
                </p>
              </div>

              <div className="flex justify-end">
                <button
                  onClick={() => onOpenProduct?.(p.id)}
                  className="inline-flex items-center whitespace-nowrap rounded-lg border border-line bg-surface px-2.5 py-1 text-sm font-medium text-body transition-colors duration-150 hover:border-faint hover:bg-page hover:text-ink"
                >
                  View details
                </button>
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
