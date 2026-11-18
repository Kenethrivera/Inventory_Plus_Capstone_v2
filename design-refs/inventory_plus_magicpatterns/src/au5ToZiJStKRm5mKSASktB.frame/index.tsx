import React from 'react'

import { AppShell } from '../shared/forecast/AppShell'
import { ForecastingHeader, ForecastTab } from '../shared/forecast/ForecastingHeader'

export const args = {}

export const argTypes = {}

type Props = { onTabChange?: (t: ForecastTab) => void }

export default function Research(props: Props) {
  return (
    <AppShell>
      <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
        <ForecastingHeader active="research" onTabChange={props.onTabChange} />
        <div className="mt-6 rounded-xl border border-dashed border-line px-6 py-16 text-center">
          <p className="text-base font-medium text-ink">Research</p>
          <p className="mx-auto mt-1 max-w-md text-sm text-muted">This tab’s content isn’t part of this mockup.</p>
        </div>
      </div>
    </AppShell>
  )
}
