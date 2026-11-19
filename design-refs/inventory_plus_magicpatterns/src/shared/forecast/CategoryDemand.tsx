import React, { useState } from 'react'

import { CATEGORY_DEMAND, UNIT_LABEL, fmt } from './data'

const VISIBLE = 5

export function CategoryDemand({ horizon, initiallyExpanded = false }: { horizon: number; initiallyExpanded?: boolean }) {
  const [expanded, setExpanded] = useState(initiallyExpanded)
  React.useEffect(() => setExpanded(initiallyExpanded), [initiallyExpanded])
  const rows = expanded ? CATEGORY_DEMAND : CATEGORY_DEMAND.slice(0, VISIBLE)

  return (
    <section className="rounded-xl border border-line bg-surface">
      <div className="px-4 pb-3 pt-4 sm:px-6 sm:pt-5">
        <h2 className="text-base font-semibold text-ink">Category demand</h2>
        <p className="mt-0.5 text-xs text-muted">{horizon === 7 ? 'Short-term (7 days)' : 'Planning (28 days)'}. Each row is one unit — rows aren’t added together.</p>
      </div>

      <table className="w-full text-sm">
        <thead>
          <tr className="border-y border-hairline bg-page/60 text-left text-xs font-medium text-muted">
            <th className="py-2 pl-4 font-medium sm:pl-6">Category</th>
            <th className="py-2 font-medium">Unit</th>
            <th className="py-2 text-right font-medium">Forecast</th>
            <th className="py-2 pr-4 text-right font-medium sm:pr-6">Change</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-hairline">
          {rows.map((r) => (
            <tr key={`${r.category}-${r.unit}`}>
              <td className="py-2.5 pl-4 text-ink sm:pl-6">{r.category}</td>
              <td className="py-2.5">
                <span className="inline-block rounded border border-line px-1.5 py-px text-xs text-body">{UNIT_LABEL[r.unit]}</span>
              </td>
              <td className="py-2.5 text-right font-medium text-ink tabular">{fmt(Math.round((r.forecast28 * horizon) / 28))}</td>
              <td className={`py-2.5 pr-4 text-right tabular sm:pr-6 ${r.change < 0 ? 'text-muted' : 'text-body'}`}>
                {r.change > 0 ? '+' : r.change < 0 ? '−' : ''}
                {Math.abs(Math.round(r.change * 100))}%
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="border-t border-hairline px-4 py-2.5 sm:px-6">
        <button onClick={() => setExpanded((e) => !e)} className="text-sm font-medium text-accent hover:text-accent-hover">
          {expanded ? 'Show fewer' : `Show all ${CATEGORY_DEMAND.length}`}
        </button>
      </div>
    </section>
  )
}
