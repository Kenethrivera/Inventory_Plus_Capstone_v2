import React, { useState } from 'react'
import { Check, Plus, Search } from 'lucide-react'

import { Popover } from './Popover'
import { CATEGORIES, MODELS, ModelId, PRODUCTS, Scope, UNITS, UNIT_LABEL, Unit, resolveScope, scopeKey } from './data'

// ---------- Forecast period ----------

const HORIZONS = [
  { id: '7', label: 'Short-term (7 days)', description: 'Short-term demand outlook' },
  { id: '28', label: 'Planning (28 days)', description: 'Restocking and inventory planning outlook' },
]

export function horizonLabel(h: string) {
  return HORIZONS.find((x) => x.id === h)?.label ?? ''
}

export function horizonDescription(h: string) {
  return HORIZONS.find((x) => x.id === h)?.description ?? ''
}

export function HorizonToggle({ value, onChange }: { value: string; onChange: (h: string) => void }) {
  return (
    <div role="radiogroup" aria-label="Forecast period" className="inline-flex shrink-0 rounded-lg border border-line bg-page p-0.5">
      {HORIZONS.map((h) => (
        <button
          key={h.id}
          role="radio"
          aria-checked={value === h.id}
          title={h.description}
          onClick={() => onChange(h.id)}
          className={`whitespace-nowrap rounded-md px-2.5 py-1 text-sm font-medium transition-colors duration-150 ${
            value === h.id ? 'bg-surface text-ink shadow-sm' : 'text-muted hover:text-ink'
          }`}
        >
          {h.label}
        </button>
      ))}
    </div>
  )
}

// ---------- Forecast method ----------

export function ForecastMethod({ value, onChange }: { value: ModelId; onChange: (m: ModelId) => void }) {
  const current = MODELS.find((m) => m.id === value) ?? MODELS[0]
  return (
    <Popover
      bare
      align="right"
      width="w-80"
      trigger={
        <span>
          Forecast method: <span className="font-medium text-body">{current.name}</span>
        </span>
      }
    >
      {(close) => (
        <div>
          <ul role="listbox">
            {MODELS.map((m) => (
              <li key={m.id}>
                <button
                  onClick={() => {
                    onChange(m.id)
                    close()
                  }}
                  className={`flex w-full items-start gap-3 rounded-lg px-3 py-2 text-left transition-colors duration-150 hover:bg-page ${
                    m.id === value ? 'bg-page' : ''
                  }`}
                >
                  <span className="mt-0.5 h-4 w-4 shrink-0">{m.id === value && <Check className="h-4 w-4 text-accent" />}</span>
                  <span className="min-w-0">
                    <span className="flex items-center gap-2 text-sm font-medium text-ink">
                      {m.name}
                      {m.tag && (
                        <span
                          className={`rounded px-1.5 py-px text-[11px] font-medium ${
                            m.tag === 'Experimental' ? 'bg-accent-soft text-accent-hover' : 'bg-page text-muted'
                          }`}
                        >
                          {m.tag}
                        </span>
                      )}
                    </span>
                    <span className="mt-0.5 block text-xs leading-relaxed text-muted">{m.description}</span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
          <p className="mx-1 mt-1.5 border-t border-hairline px-2 pb-1 pt-2 text-xs leading-relaxed text-muted">
            Changes this chart only. Restock suggestions are preliminary and always use LightGBM.
          </p>
        </div>
      )}
    </Popover>
  )
}

// ---------- Chart scope ----------

type Option = { scope: Scope; label: string; meta: string; disabled?: boolean }

function allOptions(onlyUnit?: Unit): { group: string; items: Option[] }[] {
  const unitItems: Option[] = UNITS.filter((u) => !onlyUnit || u === onlyUnit).map((u) => {
    const n = PRODUCTS.filter((p) => p.unit === u).length
    return { scope: { kind: 'unit', unit: u }, label: `All ${UNIT_LABEL[u]}`, meta: n ? `${n} products` : 'No products' }
  })
  const catItems: Option[] = CATEGORIES.filter((c) => !onlyUnit || c.units.includes(onlyUnit)).map((c) => ({
    scope: { kind: 'category', category: c.name, unit: onlyUnit ?? c.units[0] },
    label: c.name,
    meta: onlyUnit ? UNIT_LABEL[onlyUnit] : c.units.length > 1 ? `${c.units.length} units` : UNIT_LABEL[c.units[0]],
  }))
  const prodItems: Option[] = PRODUCTS.filter((p) => !onlyUnit || p.unit === onlyUnit).map((p) => ({
    scope: { kind: 'product', id: p.id },
    label: p.name,
    meta: UNIT_LABEL[p.unit],
  }))
  return [
    { group: 'Inventory unit', items: unitItems },
    { group: 'Product category', items: catItems },
    { group: 'Individual product', items: prodItems },
  ]
}

function SearchList({
  groups,
  activeKey,
  exclude = [],
  onPick,
  placeholder,
}: {
  groups: { group: string; items: Option[] }[]
  activeKey?: string
  exclude?: string[]
  onPick: (s: Scope) => void
  placeholder: string
}) {
  const [q, setQ] = useState('')
  const filtered = groups
    .map((g) => ({
      ...g,
      items: g.items.filter((o) => !exclude.includes(scopeKey(o.scope)) && o.label.toLowerCase().includes(q.trim().toLowerCase())),
    }))
    .filter((g) => g.items.length)

  return (
    <div>
      <div className="flex items-center gap-2 border-b border-hairline px-2.5 pb-2 pt-1">
        <Search className="h-4 w-4 shrink-0 text-faint" />
        <input
          autoFocus
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder={placeholder}
          className="w-full bg-transparent py-1 text-sm text-ink outline-none placeholder:text-faint"
        />
      </div>
      <div className="max-h-64 overflow-y-auto pt-1">
        {filtered.length === 0 && <p className="px-3 py-6 text-center text-sm text-muted">No matches</p>}
        {filtered.map((g) => (
          <div key={g.group} className="pb-1">
            <p className="px-3 pb-1 pt-2 text-xs font-medium text-muted">{g.group}</p>
            {g.items.map((o) => {
              const k = scopeKey(o.scope)
              const active = activeKey !== undefined && (k === activeKey || (o.scope.kind === 'category' && activeKey.startsWith(`cat:${o.scope.category}:`)))
              return (
                <button
                  key={k}
                  onClick={() => onPick(o.scope)}
                  className={`flex w-full items-center gap-2 rounded-lg px-3 py-1.5 text-left text-sm transition-colors duration-150 hover:bg-page ${active ? 'bg-page' : ''}`}
                >
                  <span className="h-4 w-4 shrink-0">{active && <Check className="h-4 w-4 text-accent" />}</span>
                  <span className="min-w-0 flex-1 truncate text-ink">{o.label}</span>
                  <span className="shrink-0 text-xs text-faint">{o.meta}</span>
                </button>
              )
            })}
          </div>
        ))}
      </div>
    </div>
  )
}

export function ScopeSelect({ value, onChange }: { value: Scope; onChange: (s: Scope) => void }) {
  const r = resolveScope(value)
  const kind = value.kind === 'unit' ? 'Unit' : value.kind === 'category' ? 'Category' : 'Product'
  return (
    <Popover
      width="w-80"
      triggerClassName="min-w-0 max-w-full sm:max-w-[18rem]"
      trigger={
        <span className="flex min-w-0 items-center gap-1.5">
          <span className="shrink-0 text-muted">{kind}</span>
          <span className="truncate font-medium text-ink">{r.label}</span>
        </span>
      }
    >
      {(close) => (
        <SearchList
          groups={allOptions()}
          activeKey={scopeKey(value)}
          placeholder="Search units, categories, products"
          onPick={(s) => {
            onChange(s)
            close()
          }}
        />
      )}
    </Popover>
  )
}

export function CategoryUnitToggle({ category, unit, onChange }: { category: string; unit: Unit; onChange: (u: Unit) => void }) {
  const units = CATEGORIES.find((c) => c.name === category)?.units ?? []
  if (units.length < 2) return null
  return (
    <div role="radiogroup" aria-label="Inventory unit" className="inline-flex shrink-0 rounded-lg border border-line bg-page p-0.5">
      {units.map((u) => (
        <button
          key={u}
          role="radio"
          aria-checked={u === unit}
          onClick={() => onChange(u)}
          className={`whitespace-nowrap rounded-md px-2.5 py-1 text-sm transition-colors duration-150 ${
            u === unit ? 'bg-surface font-medium text-ink shadow-sm' : 'text-muted hover:text-ink'
          }`}
        >
          {UNIT_LABEL[u]}
        </button>
      ))}
    </div>
  )
}

export function CompareAdd({ unit, exclude, onAdd }: { unit: Unit; exclude: string[]; onAdd: (s: Scope) => void }) {
  return (
    <Popover
      bare
      width="w-80"
      ariaLabel="Compare"
      trigger={
        <span className="flex items-center gap-1">
          <Plus className="h-3.5 w-3.5" /> Compare
        </span>
      }
    >
      {(close) => (
        <>
          <p className="px-3 pb-2 pt-1 text-xs text-muted">Add up to 2 more series measured in {UNIT_LABEL[unit]}.</p>
          <SearchList
            groups={allOptions(unit)}
            exclude={exclude}
            placeholder={`Search ${UNIT_LABEL[unit]} series`}
            onPick={(s) => {
              onAdd(s)
              close()
            }}
          />
        </>
      )}
    </Popover>
  )
}
