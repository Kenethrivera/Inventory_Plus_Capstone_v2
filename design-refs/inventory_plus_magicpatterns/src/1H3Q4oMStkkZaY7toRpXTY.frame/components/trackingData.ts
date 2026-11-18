// Demo data — illustrative only, not actual store results.

export type RestockRecord = {
  id: string
  date: string
  product: string
  unit: string
  forecast: number
  recommended: number
  actual: number | null
  saleableThen: number
  period: string
  additions: { date: string; qty: number }[]
}

export const RESTOCK_RECORDS: RestockRecord[] = [
  { id: 'r5', date: 'Mar 7', product: 'Romex 12/2 NM-B Wire', unit: 'ft', forecast: 2050, recommended: 1600, actual: null, saleableThen: 450, period: 'Mar 7 – Apr 3', additions: [] },
  { id: 'r4', date: 'Feb 28', product: 'Furnace Filter 16×25×1 MERV 8', unit: 'pcs', forecast: 92, recommended: 60, actual: 72, saleableThen: 32, period: 'Feb 28 – Mar 27', additions: [{ date: 'Mar 4', qty: 72 }] },
  { id: 'r3', date: 'Feb 21', product: 'Interior Latex Paint, Eggshell White', unit: 'gal', forecast: 72, recommended: 54, actual: 40, saleableThen: 18, period: 'Feb 21 – Mar 20', additions: [{ date: 'Feb 26', qty: 24 }, { date: 'Mar 5', qty: 16 }] },
  { id: 'r2', date: 'Feb 14', product: 'Deck Screws #8 × 2½″', unit: 'boxes', forecast: 92, recommended: 70, actual: 70, saleableThen: 22, period: 'Feb 14 – Mar 13', additions: [{ date: 'Feb 19', qty: 70 }] },
  { id: 'r1', date: 'Feb 14', product: 'Ice Melt, 50 lb Bag', unit: 'bags', forecast: 196, recommended: 180, actual: 160, saleableThen: 16, period: 'Feb 14 – Mar 13', additions: [{ date: 'Feb 18', qty: 160 }] },
]
