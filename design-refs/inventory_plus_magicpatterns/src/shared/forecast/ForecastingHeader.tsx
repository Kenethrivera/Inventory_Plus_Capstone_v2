import React from 'react'

export type ForecastTab = 'overview' | 'product' | 'tracking' | 'research'

const TABS: { id: ForecastTab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'product', label: 'Product Forecast' },
  { id: 'tracking', label: 'Tracking & Accuracy' },
  { id: 'research', label: 'Research' },
]

export function ForecastingHeader({ active, onTabChange }: { active: ForecastTab; onTabChange?: (t: ForecastTab) => void }) {
  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight text-ink">Forecasting & Restocking</h1>
      <p className="mt-1 text-sm text-muted">Updated today, 6:00 AM</p>
      <nav className="-mx-4 mt-5 overflow-x-auto border-b border-line px-4 sm:mx-0 sm:px-0" aria-label="Forecasting sections">
        <ul className="flex gap-6">
          {TABS.map((t) => (
            <li key={t.id}>
              <button
                onClick={() => onTabChange?.(t.id)}
                aria-current={t.id === active ? 'page' : undefined}
                className={`-mb-px whitespace-nowrap border-b-2 pb-2.5 text-sm font-medium transition-colors duration-150 ${
                  t.id === active ? 'border-accent text-ink' : 'border-transparent text-muted hover:text-ink'
                }`}
              >
                {t.label}
              </button>
            </li>
          ))}
        </ul>
      </nav>
    </div>
  )
}
