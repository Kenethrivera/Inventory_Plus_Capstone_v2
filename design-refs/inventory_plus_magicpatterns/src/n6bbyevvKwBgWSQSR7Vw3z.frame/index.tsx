import React, { useEffect, useState } from 'react'

import { AppShell } from '../shared/forecast/AppShell'
import { ForecastingHeader, ForecastTab } from '../shared/forecast/ForecastingHeader'
import { ForecastChart, ChartState } from '../shared/forecast/ForecastChart'
import { RestockTable } from '../shared/forecast/RestockTable'
import { CategoryDemand } from '../shared/forecast/CategoryDemand'
import { SalesGaps } from '../shared/forecast/SalesGaps'
import { ModelId } from '../shared/forecast/data'

export const args = {
  model: 'blend',
  horizon: '28',
  chartState: 'default',
  gapsExpanded: false,
  showAllCategories: false,
}

export const argTypes = {
  model: { control: 'select', options: ['blend', 'lightgbm', 'mean28', 'seasonal'] },
  horizon: { control: 'radio', options: ['7', '28'] },
  chartState: {
    control: 'select',
    options: ['default', 'loading', 'no-history', 'forecast-unavailable', 'incomplete-history', 'no-compatible'],
  },
  gapsExpanded: { control: 'boolean' },
  showAllCategories: { control: 'boolean' },
}

type Props = Partial<typeof args> & {
  onModelChange?: (m: string) => void
  onHorizonChange?: (h: string) => void
  onOpenProduct?: (id: string) => void
  onViewAccuracy?: () => void
  onTabChange?: (t: ForecastTab) => void
}

export default function Overview(props: Props) {
  const p = { ...args, ...props }
  const [model, setModel] = useState(p.model)
  const [horizon, setHorizon] = useState(p.horizon)

  useEffect(() => setModel(p.model), [p.model])
  useEffect(() => setHorizon(p.horizon), [p.horizon])

  return (
    <AppShell>
      <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
        <ForecastingHeader active="overview" onTabChange={p.onTabChange} />

        <div className="mt-6">
          <ForecastChart
            model={model as ModelId}
            horizon={horizon}
            state={p.chartState as ChartState}
            onModelChange={(m) => {
              setModel(m)
              p.onModelChange?.(m)
            }}
            onHorizonChange={(h) => {
              setHorizon(h)
              p.onHorizonChange?.(h)
            }}
            onViewAccuracy={p.onViewAccuracy}
          />
        </div>

        <div className="mt-6 grid gap-6 lg:grid-cols-5">
          <div className="lg:col-span-3">
            <RestockTable onOpenProduct={p.onOpenProduct} />
          </div>
          <div className="flex flex-col gap-6 lg:col-span-2">
            <CategoryDemand horizon={Number(horizon)} initiallyExpanded={p.showAllCategories} />
            <SalesGaps initiallyExpanded={p.gapsExpanded} />
          </div>
        </div>

        <p className="mt-8 text-xs text-faint">Sample data for demonstration only. Sales figures are simulated.</p>
      </div>
    </AppShell>
  )
}
