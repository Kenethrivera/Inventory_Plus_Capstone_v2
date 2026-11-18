import React, { useEffect, useState } from 'react'

import { AppShell } from '../shared/forecast/AppShell'
import { ForecastingHeader, ForecastTab } from '../shared/forecast/ForecastingHeader'
import { AccuracyView } from './components/AccuracyView'
import { RestockTracking } from './components/RestockTracking'

export const args = {
  section: 'accuracy',
  restockState: 'demo',
  guideOpen: false,
}

export const argTypes = {
  section: { control: 'radio', options: ['accuracy', 'restock'] },
  restockState: { control: 'radio', options: ['demo', 'empty'] },
  guideOpen: { control: 'boolean' },
}

type Props = Partial<typeof args> & { onTabChange?: (t: ForecastTab) => void }

const SECTIONS = [
  { id: 'accuracy', label: 'Forecast Accuracy', hint: 'Predicted demand vs recorded sales' },
  { id: 'restock', label: 'Restock Tracking', hint: 'Suggested restock vs stock received' },
]

export default function TrackingAccuracy(props: Props) {
  const p = { ...args, ...props }
  const [section, setSection] = useState(p.section)
  useEffect(() => setSection(p.section), [p.section])
  const restockEmpty = p.restockState === 'empty'

  return (
    <AppShell>
      <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
        <ForecastingHeader active="tracking" onTabChange={p.onTabChange} />

        <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div role="tablist" aria-label="Tracking sections" className="inline-flex self-start rounded-lg border border-line bg-page p-0.5">
            {SECTIONS.map((s) => (
              <button
                key={s.id}
                role="tab"
                aria-selected={section === s.id}
                title={s.hint}
                onClick={() => setSection(s.id)}
                className={`whitespace-nowrap rounded-md px-3 py-1.5 text-sm font-medium transition-colors duration-150 ${
                  section === s.id ? 'bg-surface text-ink shadow-sm' : 'text-muted hover:text-ink'
                }`}
              >
                {s.label}
              </button>
            ))}
          </div>
          {section === 'restock' && !restockEmpty && (
            <p className="text-xs text-muted">
              <span className="mr-1.5 rounded border border-line bg-surface px-1.5 py-0.5 font-medium text-body">Demo data</span>
              Illustrative results, not actual store performance
            </p>
          )}
        </div>
        <p className="mt-2 text-sm text-muted">{SECTIONS.find((s) => s.id === section)?.hint}.</p>

        <div className="mt-5">
          {section === 'accuracy' ? <AccuracyView guideOpen={p.guideOpen} /> : <RestockTracking empty={restockEmpty} />}
        </div>
      </div>
    </AppShell>
  )
}
