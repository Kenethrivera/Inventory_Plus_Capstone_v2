// Sample data for the mockup only — simulated sales, not real Inventory Plus results.
import { addDays, format } from 'date-fns'

export const TODAY = new Date(2025, 2, 14) // Fri, Mar 14 2025

export type ModelId = 'blend' | 'lightgbm' | 'mean28' | 'seasonal'

export const MODELS: { id: ModelId; name: string; description: string; tag?: string; band: boolean }[] = [
  { id: 'blend', name: 'Calibrated Blend', tag: 'Default', description: 'Primary calibrated demand estimate. Combines several methods and corrects for past over- or under-estimates.', band: true },
  { id: 'lightgbm', name: 'LightGBM', description: 'Machine-learning baseline that learns from past sales patterns. Used for preliminary restock suggestions.', band: true },
  { id: 'mean28', name: 'Mean28', description: 'Simple recent-demand comparison: average daily sales over the last 28 days.', band: false },
  { id: 'seasonal', name: 'Seasonal Experimental', tag: 'Experimental', description: 'Experimental model exploring seasonal behavior. Still being tested.', band: false },
]

export type Unit = 'pcs' | 'gal' | 'ft' | 'lb' | 'box' | 'bag' | 'qt'

export const UNIT_LABEL: Record<Unit, string> = {
  pcs: 'pcs',
  gal: 'gallons',
  ft: 'feet',
  lb: 'pounds',
  box: 'boxes',
  bag: 'bags',
  qt: 'quarts',
}

export const UNITS: Unit[] = ['pcs', 'bag', 'gal', 'ft', 'lb', 'box', 'qt']

export type Product = {
  id: string
  name: string
  sku: string
  category: string
  unit: Unit
  onHand: number
  dailyBase: number
  trend: number
  weekly: number
  supplier: string
  leadDays: number
  reorderPoint: number
  suggested: number
  priority: number
  reason: string
  /** Days of recorded sales history. Omitted = full history. 0 = never sold. */
  historyDays?: number
  forecastUnavailable?: boolean
  /** Units on hand that can't be sold (damaged, on hold) */
  unsaleable?: number
  /** Optional planning inputs — example values only where present */
  planning?: Partial<Record<'leadTime' | 'reviewPeriod' | 'safetyStock' | 'minOrder' | 'capacity', string>>
}

export const PRODUCTS: Product[] = [
  { id: 'p1', name: 'Ice Melt, 50 lb Bag', sku: 'SNW-50-IM', category: 'Seasonal', unit: 'bag', onHand: 14, dailyBase: 6.2, trend: -0.1, weekly: 0.5, supplier: 'Midwest Supply Co.', leadDays: 5, reorderPoint: 30, suggested: 40, priority: 1, reason: 'Covers about 2 days at forecast demand', planning: { leadTime: '5 days', minOrder: '20 bags' } },
  { id: 'p2', name: 'Deck Screws #8 × 2½″', sku: 'FST-DS8-212', category: 'Fasteners', unit: 'box', onHand: 22, dailyBase: 3.4, trend: 0.25, weekly: 0.7, supplier: 'Grip-Rite', leadDays: 7, reorderPoint: 25, suggested: 60, priority: 2, reason: 'Demand rising into deck season' },
  { id: 'p3', name: 'Interior Latex Paint, Eggshell White', sku: 'PNT-INT-EW1', category: 'Paint', unit: 'gal', onHand: 18, dailyBase: 2.6, trend: 0.15, weekly: 0.6, supplier: 'Valspar', leadDays: 6, reorderPoint: 20, suggested: 36, priority: 3, reason: 'Below reorder point', unsaleable: 2 },
  { id: 'p4', name: 'Romex 12/2 NM-B Wire', sku: 'ELC-122-NMB', category: 'Electrical', unit: 'ft', onHand: 450, dailyBase: 68, trend: 0.05, weekly: 0.2, supplier: 'Southwire', leadDays: 4, reorderPoint: 500, suggested: 1000, priority: 4, reason: 'Covers about 6 days', planning: { minOrder: '250 ft (1 spool)', capacity: '2,000 ft' } },
  { id: 'p5', name: 'Furnace Filter 16×25×1 MERV 8', sku: 'HVC-16251-M8', category: 'HVAC', unit: 'pcs', onHand: 26, dailyBase: 3.1, trend: 0.0, weekly: 0.4, supplier: 'Filtrete', leadDays: 5, reorderPoint: 24, suggested: 48, priority: 5, reason: 'Steady demand' },
  { id: 'p6', name: "Blue Painter's Tape 1.88″", sku: 'PNT-TPE-188', category: 'Paint', unit: 'pcs', onHand: 64, dailyBase: 4.2, trend: 0.1, weekly: 0.5, supplier: '3M', leadDays: 6, reorderPoint: 40, suggested: 0, priority: 9, reason: '' },
  { id: 'p7', name: 'Galvanized Common Nails 16d', sku: 'FST-GN16-LB', category: 'Fasteners', unit: 'lb', onHand: 140, dailyBase: 9.5, trend: 0.08, weekly: 0.6, supplier: 'Grip-Rite', leadDays: 7, reorderPoint: 80, suggested: 0, priority: 9, reason: '' },
  { id: 'p8', name: 'LED A19 Bulb, 4-pack', sku: 'ELC-LED-A19', category: 'Electrical', unit: 'pcs', onHand: 88, dailyBase: 5.8, trend: -0.02, weekly: 0.3, supplier: 'Philips', leadDays: 5, reorderPoint: 40, suggested: 0, priority: 9, reason: '' },
  { id: 'p9', name: 'Concrete Mix, 80 lb', sku: 'BLD-CON-80', category: 'Building', unit: 'bag', onHand: 72, dailyBase: 4.4, trend: 0.3, weekly: 0.9, supplier: 'Quikrete', leadDays: 3, reorderPoint: 40, suggested: 0, priority: 9, reason: '' },
  { id: 'p10', name: 'PVC Pipe ½″ × 10 ft', sku: 'PLB-PVC-050', category: 'Plumbing', unit: 'pcs', onHand: 55, dailyBase: 3.9, trend: 0.04, weekly: 0.3, supplier: 'Charlotte Pipe', leadDays: 4, reorderPoint: 30, suggested: 0, priority: 9, reason: '' },
  { id: 'p11', name: 'Teflon Thread Tape ½″', sku: 'PLB-PTFE-050', category: 'Plumbing', unit: 'pcs', onHand: 120, dailyBase: 2.2, trend: 0.0, weekly: 0.2, supplier: 'Oatey', leadDays: 4, reorderPoint: 30, suggested: 0, priority: 9, reason: '' },
  { id: 'p12', name: 'Garden Hose, 50 ft', sku: 'GRD-HOSE-50', category: 'Garden', unit: 'pcs', onHand: 30, dailyBase: 1.4, trend: 0.6, weekly: 0.8, supplier: 'Flexzilla', leadDays: 8, reorderPoint: 12, suggested: 0, priority: 9, reason: '', historyDays: 19 },
  { id: 'p13', name: 'Brass Gate Valve ¾″', sku: 'PLB-GV-075', category: 'Plumbing', unit: 'pcs', onHand: 8, dailyBase: 0, trend: 0, weekly: 0, supplier: 'NIBCO', leadDays: 6, reorderPoint: 4, suggested: 0, priority: 9, reason: '', historyDays: 0 },
  { id: 'p14', name: 'Wet/Dry Vac Cartridge Filter', sku: 'TLS-WDV-CF', category: 'Tools', unit: 'pcs', onHand: 15, dailyBase: 0.6, trend: 0, weekly: 0.5, supplier: 'Shop-Vac', leadDays: 7, reorderPoint: 6, suggested: 0, priority: 9, reason: '', forecastUnavailable: true },
]


export const NO_SALES: { name: string; sku: string; onHand: number; unit: Unit; lastReceived: string }[] = [
  { name: 'Brass Gate Valve ¾″', sku: 'PLB-GV-075', onHand: 8, unit: 'pcs', lastReceived: 'Nov 2, 2024' },
  { name: 'Copper Pipe Cutter, Mini', sku: 'TLS-CPC-MINI', onHand: 6, unit: 'pcs', lastReceived: 'Oct 18, 2024' },
  { name: 'Chimney Brush 8″ Round', sku: 'HVC-CB-8R', onHand: 4, unit: 'pcs', lastReceived: 'Sep 30, 2024' },
  { name: 'Marine Varnish, Gloss', sku: 'PNT-MV-GL', onHand: 5, unit: 'gal', lastReceived: 'Dec 5, 2024' },
  { name: 'Stainless Chain 3/16″', sku: 'HRD-SSC-316', onHand: 120, unit: 'ft', lastReceived: 'Nov 21, 2024' },
  { name: 'Lag Shields ⅜″, bulk', sku: 'FST-LS-038', onHand: 9, unit: 'lb', lastReceived: 'Oct 7, 2024' },
  { name: 'Weatherstrip Door Sweep 36″', sku: 'HRD-WDS-36', onHand: 11, unit: 'pcs', lastReceived: 'Jan 9, 2025' },
]

export type CategoryRow = { category: string; unit: Unit; forecast28: number; change: number }

export const CATEGORY_DEMAND: CategoryRow[] = [
  { category: 'Electrical', unit: 'ft', forecast28: 1960, change: 0.05 },
  { category: 'Fasteners', unit: 'lb', forecast28: 284, change: 0.08 },
  { category: 'Paint', unit: 'gal', forecast28: 81, change: 0.14 },
  { category: 'Seasonal', unit: 'bag', forecast28: 142, change: -0.22 },
  { category: 'Electrical', unit: 'pcs', forecast28: 162, change: -0.02 },
  { category: 'Fasteners', unit: 'box', forecast28: 104, change: 0.24 },
  { category: 'Plumbing', unit: 'pcs', forecast28: 171, change: 0.03 },
  { category: 'Paint', unit: 'pcs', forecast28: 126, change: 0.1 },
  { category: 'HVAC', unit: 'pcs', forecast28: 87, change: 0.0 },
  { category: 'Building', unit: 'bag', forecast28: 139, change: 0.29 },
  { category: 'Garden', unit: 'pcs', forecast28: 52, change: 0.61 },
]

// ---------- Chart scope ----------

export type Scope =
  | { kind: 'unit'; unit: Unit }
  | { kind: 'category'; category: string; unit: Unit }
  | { kind: 'product'; id: string }

export const CATEGORIES: { name: string; units: Unit[] }[] = Array.from(new Set(PRODUCTS.map((p) => p.category)))
  .sort()
  .map((name) => {
    const counts = new Map<Unit, number>()
    PRODUCTS.filter((p) => p.category === name).forEach((p) => counts.set(p.unit, (counts.get(p.unit) ?? 0) + 1))
    return { name, units: [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([u]) => u) }
  })

export const DEFAULT_SCOPE: Scope = { kind: 'unit', unit: 'pcs' } // largest group with full history

export function scopeKey(s: Scope) {
  return s.kind === 'unit' ? `unit:${s.unit}` : s.kind === 'category' ? `cat:${s.category}:${s.unit}` : `prod:${s.id}`
}

export function resolveScope(s: Scope) {
  if (s.kind === 'product') {
    const p = PRODUCTS.find((x) => x.id === s.id)!
    return { label: p.name, short: p.name, unit: p.unit, products: [p] }
  }
  if (s.kind === 'unit') {
    const products = PRODUCTS.filter((p) => p.unit === s.unit)
    return { label: `All items · ${UNIT_LABEL[s.unit]}`, short: `All ${UNIT_LABEL[s.unit]}`, unit: s.unit, products }
  }
  const products = PRODUCTS.filter((p) => p.category === s.category && p.unit === s.unit)
  return { label: s.category, short: `${s.category} (${UNIT_LABEL[s.unit]})`, unit: s.unit, products }
}

// ---------- Series ----------

export type Series = {
  actual: (number | null)[]
  forecast: (number | null)[]
  low: (number | null)[] | null
  high: (number | null)[] | null
  /** No product in scope has any recorded sales */
  noHistory: boolean
  /** Products in scope have no forecast */
  forecastUnavailable: boolean
  /** Earliest day with recorded sales, when later than the window start */
  historyStart: Date | null
  /** Estimated demand for today */
  today: number | null
}

export function timeline(horizon: number) {
  const histDays = horizon === 7 ? 28 : 56
  const dates = Array.from({ length: histDays + horizon }, (_, i) => addDays(TODAY, i - histDays + 1))
  return { dates, todayIdx: histDays - 1, histDays }
}

function noise(seed: number) {
  const x = Math.sin(seed * 12.9898) * 43758.5453
  return x - Math.floor(x) - 0.5
}

function weekdayFactor(d: Date, weekly: number) {
  const day = d.getDay()
  if (day === 6) return 1 + weekly
  if (day === 0) return 1 + weekly * 0.6
  if (day === 1) return 0.85
  return 1
}

const TUNING: Record<ModelId, { lift: number; season: number; band: number; flat: boolean }> = {
  blend: { lift: 1.0, season: 1.0, band: 0.14, flat: false },
  lightgbm: { lift: 1.05, season: 1.1, band: 0.18, flat: false },
  mean28: { lift: 1.0, season: 0, band: 0, flat: true },
  seasonal: { lift: 1.02, season: 1.6, band: 0, flat: false },
}

export function buildSeries(products: Product[], horizon: number, model: ModelId): Series {
  const { dates, todayIdx, histDays } = timeline(horizon)
  const withSales = products.filter((p) => p.historyDays !== 0)
  const forecastable = withSales.filter((p) => !p.forecastUnavailable)
  const tune = TUNING[model]
  const hasBand = MODELS.find((m) => m.id === model)!.band

  const actual: (number | null)[] = dates.map((d, i) => {
    if (i > todayIdx) return null
    const active = withSales.filter((p) => p.historyDays === undefined || i > todayIdx - p.historyDays)
    if (!active.length) return null
    const v = active.reduce((sum, p, k) => {
      const t = 1 + p.trend * ((i - histDays) / histDays)
      return sum + Math.max(0, p.dailyBase * t * weekdayFactor(d, p.weekly) * (1 + noise(i * 7 + Number(p.id.slice(1)) * 31 + k) * 0.5))
    }, 0)
    return Math.round(v)
  })

  const recent = actual.slice(Math.max(0, todayIdx - 27), todayIdx + 1).filter((v): v is number => v !== null)
  const mean = recent.length ? recent.reduce((a, b) => a + b, 0) / recent.length : 0

  const estimate = (d: Date, j: number) => {
    if (tune.flat) return Math.round(mean * 10) / 10
    const f = forecastable.reduce((sum, p) => {
      const t = 1 + p.trend * (j / histDays)
      return sum + p.dailyBase * t * (1 + (weekdayFactor(d, p.weekly) - 1) * tune.season)
    }, 0)
    return Math.round(f * tune.lift * 10) / 10
  }

  const forecast: (number | null)[] = dates.map((d, i) => {
    if (i < todayIdx || !forecastable.length) return null
    if (i === todayIdx) return actual[i]
    return estimate(d, i - todayIdx)
  })

  let low: (number | null)[] | null = null
  let high: (number | null)[] | null = null
  if (hasBand && forecastable.length) {
    low = forecast.map((f, i) => (f === null ? null : i === todayIdx ? f : Math.max(0, f * (1 - tune.band * (1 + (i - todayIdx) / (horizon * 1.5))))))
    high = forecast.map((f, i) => (f === null ? null : i === todayIdx ? f : f * (1 + tune.band * (1 + (i - todayIdx) / (horizon * 1.5)))))
  }

  const firstIdx = actual.findIndex((v) => v !== null)
  return {
    actual,
    forecast,
    low,
    high,
    noHistory: withSales.length === 0,
    forecastUnavailable: withSales.length > 0 && forecastable.length === 0,
    historyStart: firstIdx > 0 ? dates[firstIdx] : null,
    today: forecastable.length ? estimate(TODAY, 0) : null,
  }
}

/** Preliminary restock: LightGBM 28-day demand minus saleable stock. */
export function restockFor(p: Product) {
  const s = buildSeries([p], 28, 'lightgbm')
  const saleable = p.onHand - (p.unsaleable ?? 0)
  if (s.noHistory || s.forecastUnavailable) return { available: false as const, saleable, demand28: 0, suggested: 0, daily: 0 }
  const demand28 = summarize(s, timeline(28).todayIdx, 28).forecast
  return { available: true as const, saleable, demand28, suggested: Math.max(0, Math.ceil(demand28 - saleable)), daily: demand28 / 28 }
}

export function summarize(s: Series, todayIdx: number, horizon: number) {
  const fut = (arr: (number | null)[] | null) => (arr ? arr.slice(todayIdx + 1).reduce<number>((a, b) => a + (b ?? 0), 0) : null)
  const fc = fut(s.forecast) ?? 0
  const priorVals = s.actual.slice(todayIdx + 1 - horizon, todayIdx + 1)
  const priorComplete = priorVals.every((v) => v !== null)
  const prior = priorVals.reduce<number>((a, b) => a + (b ?? 0), 0)
  const low = fut(s.low)
  const high = fut(s.high)
  return {
    forecast: Math.round(fc),
    change: priorComplete && prior ? (fc - prior) / prior : null,
    low: low === null ? null : Math.round(low),
    high: high === null ? null : Math.round(high),
  }
}

export function fmt(n: number) {
  return n.toLocaleString('en-US')
}

export function dayLabel(d: Date) {
  return format(d, 'MMM d')
}

export const RESTOCK = PRODUCTS.filter((p) => p.priority < 9)
  .sort((a, b) => a.priority - b.priority)
  .map((p) => ({ ...p, suggested: restockFor(p).suggested }))
  .slice(0, 5)
