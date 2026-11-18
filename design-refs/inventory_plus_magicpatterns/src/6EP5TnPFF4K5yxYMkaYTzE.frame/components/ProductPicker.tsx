import React, { useEffect, useRef, useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { Check, ChevronDown, ChevronLeft, ChevronRight, Search } from 'lucide-react'

import { PRODUCTS, UNIT_LABEL } from '../../shared/forecast/data'

export function ProductPicker({ value, onChange }: { value: string; onChange: (id: string) => void }) {
  const [open, setOpen] = useState(false)
  const [q, setQ] = useState('')
  const ref = useRef<HTMLDivElement>(null)
  const idx = PRODUCTS.findIndex((p) => p.id === value)
  const current = PRODUCTS[idx] ?? PRODUCTS[0]

  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setOpen(false)
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false)
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  const matches = PRODUCTS.filter((p) => {
    const s = q.trim().toLowerCase()
    return !s || p.name.toLowerCase().includes(s) || p.sku.toLowerCase().includes(s) || p.category.toLowerCase().includes(s)
  })
  const go = (d: number) => onChange(PRODUCTS[(idx + d + PRODUCTS.length) % PRODUCTS.length].id)

  return (
    <div className="flex items-start justify-between gap-3">
      <div ref={ref} className="relative min-w-0">
        <button
          onClick={() => {
            setOpen((o) => !o)
            setQ('')
          }}
          aria-expanded={open}
          className="-ml-2 flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 text-left transition-colors duration-150 hover:bg-surface"
        >
          <span className="truncate text-xl font-semibold tracking-tight text-ink sm:text-2xl">{current.name}</span>
          <ChevronDown className={`h-5 w-5 shrink-0 text-muted transition-transform duration-150 ${open ? 'rotate-180' : ''}`} />
        </button>

        <AnimatePresence>
          {open && (
            <motion.div
              initial={{ opacity: 0, y: -4, scale: 0.98 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={{ opacity: 0, y: -4, scale: 0.98 }}
              transition={{ duration: 0.16, ease: [0.23, 1, 0.32, 1] }}
              style={{ transformOrigin: 'top left' }}
              className="absolute left-0 z-20 mt-1.5 w-[22rem] max-w-[calc(100vw-2rem)] rounded-xl border border-line bg-surface p-1.5 shadow-lg shadow-ink/5"
            >
              <div className="flex items-center gap-2 border-b border-hairline px-2.5 pb-2 pt-1">
                <Search className="h-4 w-4 shrink-0 text-faint" />
                <input
                  autoFocus
                  value={q}
                  onChange={(e) => setQ(e.target.value)}
                  placeholder="Search product, SKU or category"
                  className="w-full bg-transparent py-1 text-sm text-ink outline-none placeholder:text-faint"
                />
              </div>
              <ul className="max-h-72 overflow-y-auto pt-1">
                {matches.length === 0 && <li className="px-3 py-6 text-center text-sm text-muted">No matching products</li>}
                {matches.map((p) => (
                  <li key={p.id}>
                    <button
                      onClick={() => {
                        onChange(p.id)
                        setOpen(false)
                      }}
                      className={`flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left transition-colors duration-150 hover:bg-page ${
                        p.id === current.id ? 'bg-page' : ''
                      }`}
                    >
                      <span className="h-4 w-4 shrink-0">{p.id === current.id && <Check className="h-4 w-4 text-accent" />}</span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm text-ink">{p.name}</span>
                        <span className="block truncate text-xs text-muted">
                          {p.category} · {p.sku}
                        </span>
                      </span>
                      <span className="shrink-0 text-xs text-faint">{UNIT_LABEL[p.unit]}</span>
                    </button>
                  </li>
                ))}
              </ul>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <div className="flex shrink-0 items-center gap-1 pt-1">
        <span className="mr-1 hidden text-xs text-muted tabular sm:inline">
          {idx + 1} of {PRODUCTS.length}
        </span>
        <button
          onClick={() => go(-1)}
          aria-label="Previous product"
          className="rounded-lg border border-line bg-surface p-1.5 text-muted transition-colors duration-150 hover:text-ink"
        >
          <ChevronLeft className="h-4 w-4" />
        </button>
        <button
          onClick={() => go(1)}
          aria-label="Next product"
          className="rounded-lg border border-line bg-surface p-1.5 text-muted transition-colors duration-150 hover:text-ink"
        >
          <ChevronRight className="h-4 w-4" />
        </button>
      </div>
    </div>
  )
}
