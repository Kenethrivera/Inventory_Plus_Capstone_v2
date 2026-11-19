import React, { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { ChevronDown } from 'lucide-react'

const STATUS = [
  { label: 'Saved forecasts monitored', value: '3' },
  { label: 'Completed forecast periods', value: '0' },
  { label: 'Status', value: 'Awaiting first completed period' },
]

const GUIDE = [
  { range: 'Under 10%', meaning: 'Very close' },
  { range: '10–20%', meaning: 'Generally useful for planning' },
  { range: '20–35%', meaning: 'Directional only' },
  { range: 'Above 35%', meaning: 'Use with extra caution' },
]

export function AccuracyView({ guideOpen = false }: { guideOpen?: boolean }) {
  const [open, setOpen] = useState(guideOpen)
  React.useEffect(() => setOpen(guideOpen), [guideOpen])

  return (
    <div className="grid items-start gap-6 lg:grid-cols-5">
      <section className="rounded-xl border border-line bg-surface lg:col-span-3">
        <div className="px-4 pt-5 sm:px-6">
          <h2 className="text-base font-semibold text-ink">Forecast performance</h2>
          <p className="mt-1.5 max-w-xl text-sm leading-relaxed text-body">
            Forecast accuracy will appear after a saved forecast period fully ends and enough actual sales data is available for comparison.
          </p>
        </div>
        <dl className="mt-5 grid divide-y divide-hairline border-t border-hairline sm:grid-cols-[auto_auto_minmax(0,1fr)] sm:divide-x sm:divide-y-0">
          {STATUS.map((s) => (
            <div key={s.label} className="flex items-baseline justify-between gap-4 px-4 py-3.5 sm:block sm:px-6 sm:py-4">
              <dt className="text-xs text-muted">{s.label}</dt>
              <dd className={`text-right sm:mt-1 sm:text-left ${s.label === 'Status' ? 'text-sm font-medium text-body' : 'text-2xl font-semibold text-ink tabular'}`}>
                {s.value}
              </dd>
            </div>
          ))}
        </dl>
      </section>

      <section className="rounded-xl border border-line bg-surface px-4 py-5 sm:px-6 lg:col-span-2">
        <h2 className="text-base font-semibold text-ink">How to read forecast results</h2>
        <dl className="mt-3 space-y-3 text-sm leading-relaxed">
          <div>
            <dt className="font-medium text-ink">WAPE</dt>
            <dd className="text-body">Lower means forecasts were closer to actual sales overall.</dd>
          </div>
          <div>
            <dt className="font-medium text-ink">Bias</dt>
            <dd className="text-body">Positive means forecasts tended to predict too much; negative means too little.</dd>
          </div>
          <div>
            <dt className="font-medium text-ink">Keep in mind</dt>
            <dd className="text-body">Forecasts are planning aids, not exact sales guarantees.</dd>
          </div>
        </dl>

        <button
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          className="mt-4 inline-flex items-center gap-1 text-sm font-medium text-muted hover:text-ink"
        >
          General guide to WAPE
          <ChevronDown className={`h-4 w-4 transition-transform duration-200 ${open ? 'rotate-180' : ''}`} />
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
              <dl className="mt-2 divide-y divide-hairline rounded-lg bg-page px-3 text-sm">
                {GUIDE.map((g) => (
                  <div key={g.range} className="flex items-baseline justify-between gap-4 py-2">
                    <dt className="shrink-0 text-ink tabular">{g.range}</dt>
                    <dd className="text-right text-muted">{g.meaning}</dd>
                  </div>
                ))}
              </dl>
              <p className="mt-2 text-xs text-muted">A rough reference — usefulness also depends on the product and how much it sells.</p>
            </motion.div>
          )}
        </AnimatePresence>
      </section>
    </div>
  )
}
