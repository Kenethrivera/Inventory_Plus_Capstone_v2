import React, { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { ChevronDown } from 'lucide-react'

import { NO_SALES, UNIT_LABEL, fmt } from './data'

export function SalesGaps({ initiallyExpanded = false }: { initiallyExpanded?: boolean }) {
  const [open, setOpen] = useState(initiallyExpanded)
  React.useEffect(() => setOpen(initiallyExpanded), [initiallyExpanded])

  return (
    <section className="rounded-xl border border-line bg-surface">
      <button
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex w-full items-center gap-4 px-4 py-4 text-left sm:px-6 sm:py-5"
      >
        <span className="text-2xl font-semibold text-ink tabular">{NO_SALES.length}</span>
        <span className="min-w-0 flex-1">
          <span className="block text-sm font-medium text-ink">Products with no recorded sales</span>
          <span className="block text-xs text-muted">In stock, nothing sold in 90 days. Can’t be forecast yet.</span>
        </span>
        <ChevronDown className={`h-4 w-4 shrink-0 text-muted transition-transform duration-200 ${open ? 'rotate-180' : ''}`} />
      </button>

      <AnimatePresence initial={false}>
        {open && (
          <motion.div
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.22, ease: [0.23, 1, 0.32, 1] }}
            className="overflow-hidden"
          >
            <ul className="divide-y divide-hairline border-t border-hairline">
              {NO_SALES.map((p) => (
                <li key={p.sku} className="flex items-center justify-between gap-4 px-4 py-2.5 sm:px-6">
                  <div className="min-w-0">
                    <p className="truncate text-sm text-ink">{p.name}</p>
                    <p className="text-xs text-muted">Received {p.lastReceived}</p>
                  </div>
                  <p className="shrink-0 text-sm text-body tabular">
                    {fmt(p.onHand)} <span className="text-xs text-muted">{UNIT_LABEL[p.unit]}</span>
                  </p>
                </li>
              ))}
            </ul>
          </motion.div>
        )}
      </AnimatePresence>
    </section>
  )
}
