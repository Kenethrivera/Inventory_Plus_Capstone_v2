# Product Forecast UI Specification

## 1. Design reference and verified source files

This specification covers only the **Product Forecast** tab within **Forecasting & Restocking**.

The approved source is the exact Magic Patterns export requested by project identifier:

- Archive: `design-refs/afcadf46-bf75-4c82-9a54-fea343d60e49.zip`
- Size: 143,416 bytes
- SHA-256: `792EE0CF3DD812D0D6C71C3A3077CCADD57EACA9F12A1CF8CCE71BA13A9C307A`
- Export README mapping: `pages/product-detail/` -> `src/6EP5TnPFF4K5yxYMkaYTzE.frame`
- Verified default export: `ProductForecast`

The archive was inspected directly. The React application was not installed, built, or run.

### Product Forecast source files inspected

- `src/6EP5TnPFF4K5yxYMkaYTzE.frame/index.tsx` — page composition, state, period summaries, and responsive layout.
- `src/6EP5TnPFF4K5yxYMkaYTzE.frame/index.css` — Product Forecast theme tokens and font.
- `src/6EP5TnPFF4K5yxYMkaYTzE.frame/components/ProductPicker.tsx` — selector, search menu, and previous/next controls.
- `src/6EP5TnPFF4K5yxYMkaYTzE.frame/components/RestockPanel.tsx` — preliminary restock card and states.
- `src/6EP5TnPFF4K5yxYMkaYTzE.frame/components/ForecastContext.tsx` — limitations and About This Forecast cards.
- `src/shared/forecast/ForecastChart.tsx` — chart state selection and Product Forecast embedding behavior.
- `src/shared/forecast/DemandChart.tsx` — chart geometry, series, axes, legends, and hover tooltip.
- `src/shared/forecast/Controls.tsx` — forecast-method menu and model descriptions.
- `src/shared/forecast/Popover.tsx` — shared anchored-menu dimensions, alignment, dismissal, and animation.
- `src/shared/forecast/data.ts` — prototype model list, units, simulated series, period totals, and preliminary restock formula.
- `src/shared/forecast/ForecastingHeader.tsx` — confirmation that Product Forecast is the active tab; global tab styling is outside this specification.
- `README.md` and `package.json` — route verification and dependency versions.

The prototype data in `data.ts` is explicitly simulated. Its product names, quantities, dates, confidence ranges, and sales history must not be copied into Flutter.

## 2. Component hierarchy

Observed hierarchy in `ProductForecast`:

```text
ProductForecast
├─ existing Forecasting & Restocking page header/tab navigation
├─ Product identity block
│  ├─ ProductPicker
│  │  ├─ selected product trigger
│  │  ├─ anchored searchable product menu
│  │  └─ product count + previous/next controls
│  └─ category · SKU · selling unit · current stock metadata
├─ Primary grid
│  ├─ Forecast card (2 of 3 desktop columns)
│  │  ├─ period strip
│  │  │  ├─ Today
│  │  │  ├─ Short-term (7 days)
│  │  │  └─ Planning (28 days)
│  │  └─ chart body
│  │     ├─ chart title + selected-period caption
│  │     ├─ ForecastMethod popover trigger
│  │     ├─ ForecastChart (embedded, locked to selected product)
│  │     │  └─ DemandChart
│  │     └─ chart legend/footer actions
│  └─ RestockPanel (1 of 3 desktop columns)
├─ ForecastContext grid
│  ├─ Important Forecast Limitations
│  └─ About this forecast
└─ demo-data footnote in prototype only
```

Prototype defaults are product `p1`, model `blend`, horizon `28`, and collapsed limitations. Flutter must use its current selected product, selected model, selected window, and live API state instead.

## 3. Desktop layout

### Page content constraints

- Main content is centered with `max-w-7xl`: maximum width **1280 px**.
- Horizontal page padding is **16 px** below 640 px, **24 px** from 640 px, and **40 px** from 1024 px.
- Vertical page padding is **24 px**, increasing to **32 px** from 1024 px.
- The existing Flutter Forecasting page already supplies the page title and tab navigation. Product Forecast implementation must not create a second global header.

### Product identity block

- Starts **24 px** below the Forecasting tab navigation.
- Selector/control row uses a horizontal flex layout, top-aligned, with a **12 px** gap.
- Selected product trigger occupies remaining width and truncates long names.
- Previous/next controls remain fixed-width at the right.
- Metadata line starts **6 px** below the selector (`mt-1.5`), wraps as needed, and uses **8 px** horizontal and **4 px** vertical gaps.

Metadata order is:

```text
Category · SKU · Sold in {unit} · {stock quantity} {unit} in stock
```

Flutter must use truthful live terminology. If the number is saleable stock rather than total on-hand stock, label it `saleable`, as the current Flutter implementation does.

### Primary forecast/recommendation grid

- Starts **24 px** below the product identity block.
- Grid gap: **24 px**.
- At widths of **1024 px and above**, use three equal grid tracks:
  - Forecast card: columns 1–2, approximately two thirds of available width.
  - Restock recommendation: column 3, approximately one third.
- Cards align at their top edges.
- Below 1024 px the cards become one column, forecast first and recommendation second.

### Forecast card

- White surface.
- **1 px** `line` border.
- **12 px** corner radius.
- Content clipped to the rounded boundary.
- No shadow.

The period strip is the top portion of this same card, not three separate floating cards. At 640 px and above it is a three-column grid with vertical dividers. Its bottom edge has a `hairline` divider. Each cell uses **24 px horizontal / 20 px vertical** padding at desktop.

The chart body uses **24 px** padding at 640 px and above. The chart heading and method selector share one flex row, wrap if necessary, align vertically centered, and have a **16 px** bottom margin before the chart.

### Recommendation card

- White surface.
- **1 px** `line` border.
- **12 px** corner radius.
- **24 px** padding at 640 px and above.
- Uses a vertical flex column so the LightGBM disclaimer can sit at the bottom at desktop height.
- No shadow.

### Limitations/About row

- Starts **24 px** below the primary grid.
- At widths of **768 px and above**, it is a two-column grid with equal columns and a **24 px** gap.
- Below 768 px it becomes a single column, limitations first and About second.
- The two cards top-align; equal height is not required by the source.

The prototype-only final footnote is `Example products and simulated sales for demonstration only.` at **12 px**, faint text, **32 px** above it. In Flutter it must not appear for real data. Existing synthetic/SIM warnings are the truthful replacement and must remain conditional.

## 4. Mobile layout

Tailwind breakpoints observed in the export:

| Breakpoint | Width | Product Forecast behavior |
|---|---:|---|
| Base | `<640 px` | 16 px page padding; product count hidden; period cells stack; cards use 16 px padding. |
| `sm` | `>=640 px` | 24 px page padding; product count shown; three period cells become one row; cards use 24 px padding. |
| `md` | `>=768 px` | limitations and About become two columns. |
| `lg` | `>=1024 px` | 40 px page padding; forecast/recommendation become 2:1 columns. |

Mobile-specific requirements:

- Long product names truncate on one line; the selector chevron and previous/next buttons cannot be pushed off-screen.
- Product metadata wraps rather than horizontally scrolling.
- Product menu width is **352 px** (`22rem`) but constrained to `viewport width - 32 px`.
- Below 640 px, the Today, 7-day, and 28-day cells stack vertically. Source separators switch from vertical to horizontal.
- The chart remains **260 px** high. Its measured width has a prototype minimum of **280 px**.
- Chart legend and footer links wrap onto additional lines.
- Forecast method popover width is **320 px** but constrained to `viewport width - 32 px` and is right-aligned to its trigger.
- Forecast and recommendation cards stack below 1024 px. Limitations and About stack below 768 px.

## 5. Visual styling

### Theme tokens

| Token | Exact value | Use in Product Forecast |
|---|---|---|
| Font | `Inter`, system sans fallback | All text |
| `accent` | `#EA580C` | forecast line, checks, active emphasis |
| `accent-hover` | `#C2410C` | recommendation quantity, accent hover |
| `accent-soft` | `#FFF4EC` | positive-restock panel, experimental tag |
| `accent-line` | `#FDD8BF` | available accent border token |
| `ink` | `#1C1917` | primary text |
| `body` | `#44403C` | body copy and secondary strong text |
| `muted` | `#78716C` | labels and descriptions |
| `faint` | `#A8A29E` | separators, tertiary text |
| `line` | `#E7E5E4` | card and control borders |
| `hairline` | `#F0EFED` | internal dividers/grid |
| `page` | `#F7F7F6` | page and selected/hover fills |
| `surface` | `#FFFFFF` | cards and menus |
| `series-1` | `#57534E` | actual-sales line |
| `series-2` | `#EA580C` | secondary comparison token |
| `series-3` | `#0F766E` | third comparison token |
| `caution` | `#D97706` | limitation icon, left border, bullets |
| `caution-soft` | `#FFFBEB` | limitation background |
| `caution-ink` | `#92400E` | limitation heading/action |

Numeric quantities use tabular numerals.

### Typography

- Selected product: **20 px**, 600 weight, tight tracking; **24 px** from 640 px.
- Product metadata: **14 px**, 400; stock quantity within it is 600.
- Period label: **12 px**, muted; **14 px** from 640 px.
- Period value: **20 px**, 600, tight tracking; **24 px** from 640 px.
- Period unit: **14 px**, 500, muted.
- Period note/range: **12 px**, muted.
- Chart title: **14 px**, 500.
- Forecast-method trigger: **14 px**; selected method is 500.
- Recommendation title: **14 px**, 500.
- Positive recommendation quantity: **48 px**, 600, tight tracking, `accent-hover`.
- Recommendation unit: **18 px**, 500, `body`.
- Recommendation explanation and metric rows: **14 px**.
- Limitations/About headings: **14 px**, 600.
- Limitations and About rows: **14 px**.
- Tertiary provenance/demo label: **12 px**, faint.

### Borders, radii, shadows, and icons

- Cards: 1 px border, 12 px radius, no shadow.
- Highlight panel inside recommendation: 8 px radius.
- Selector and option rows: 8 px radius.
- Small arrow buttons: 1 px border, 8 px radius, **6 px** padding, 16 px Lucide icons.
- Menus: 1 px border, 12 px radius, **6 px** internal padding, Tailwind `shadow-lg shadow-ink/5`.
- Product/method menus animate for **160 ms** from opacity 0, `y=-4`, scale 0.98 to the resting state using cubic Bézier `[0.23, 1, 0.32, 1]`.
- Lucide icons used by Product Forecast: `ChevronDown`, `ChevronLeft`, `ChevronRight`, `Search`, `Check`, `AlertTriangle`, `Info`, and `ArrowRight`. The chart comparison `X` icon is not used when scope is locked to one product.

## 6. Interactive behavior

### Product selector

Observed behavior:

- Trigger shows the selected product name followed by a down chevron.
- Clicking toggles an anchored menu immediately below and left-aligned with the trigger.
- Opening/toggling clears the previous search query.
- Menu width: 352 px, capped at viewport width minus 32 px.
- Search field is focused automatically.
- Search is case-insensitive and matches product name, SKU, or category.
- Results region has a maximum height of **288 px** and scrolls vertically.
- Each option shows:
  - a 16 px check for the selected product;
  - product name;
  - `Category · SKU` on a second line;
  - selling unit at right.
- Selecting an option changes the product and closes the menu.
- Clicking outside or pressing Escape closes the menu.
- `No matching products` is centered when the result list is empty.
- Product count is `{index + 1} of {total}` and is hidden below 640 px.
- Previous and next controls wrap cyclically from first to last and last to first.

Existing Flutter product state already reloads/uses the selected analysis and preserves product-specific tracking state. The visual implementation must call the existing `_selectProduct(..., loadForecast: true)` path; it must not introduce a parallel selection state.

### Forecast period

- Today is informational and not clickable in the prototype.
- Short-term and Planning cells are buttons.
- Clicking a period changes the chart horizon and period caption.
- Selected period has a subtle `page/40` fill and a **2 px** orange bar along its bottom edge.
- Hover has `page/60` fill.
- Default period is Planning (28 days).

### Forecast method selector

Observed options, in order:

| Prototype ID | Label | Tag | Description |
|---|---|---|---|
| `blend` | Calibrated Blend | Default | Primary calibrated demand estimate. Combines several methods and corrects for past over- or under-estimates. |
| `lightgbm` | LightGBM | none | Machine-learning baseline that learns from past sales patterns. Used for preliminary restock suggestions. |
| `mean28` | Mean28 | none | Simple recent-demand comparison: average daily sales over the last 28 days. |
| `seasonal` | Seasonal Experimental | Experimental | Experimental model exploring seasonal behavior. Still being tested. |

Flutter model IDs are `calibrated_blend`, `lightgbm`, `mean28`, and `seasonal_experimental`; those existing IDs must be retained.

Menu behavior:

- Trigger is a borderless compact control reading `Forecast method: {selected name}` plus a down chevron.
- Menu is 320 px wide, right-aligned, and capped at viewport width minus 32 px.
- Selected option receives a page-colored background and orange check.
- Default/Experimental tags use 11 px text; Experimental uses accent-soft/accent-hover.
- Selection changes the chart forecast model and closes the menu.
- Clicking outside or pressing Escape closes the menu.
- The footer states: `Changes this chart only. Restock suggestions are preliminary and always use LightGBM.`

The current Flutter implementation reloads analysis when the model changes. Preserve this behavior and preserve the strict separation between selected chart model and the LightGBM preliminary recommendation.

### Limitations disclosure

- Default state shows two bullets.
- The prototype contains two additional bullets and therefore always shows `Read all limitations (4)`.
- Clicking expands the additional list with a **200 ms** height/opacity animation using `[0.23, 1, 0.32, 1]`.
- Expanded action text is `Show less`.
- `aria-expanded` reflects the state.
- In Flutter, append live API warnings after the four general limitations. Display the first two general limitations by default and place the remaining general limitations plus API warnings in the expanded region.
- Show the disclosure action only when the total limitation count exceeds two. Its count must reflect the actual total.

## 7. Chart specification

### Placement and title

The chart is embedded inside the forecast card; it does not render its own outer card or scope/horizon controls. It is locked to the selected product.

The parent heading is:

```text
Daily sales and forecast · next 7 days shown
```

or:

```text
Daily sales and forecast · next 28 days shown
```

The method selector is right-aligned in the same heading row.

### Geometry

- SVG/chart height: **260 px**.
- Responsive measured width, with prototype minimum **280 px**.
- Plot padding: top **16 px**, right **12 px**, bottom **28 px**, left **44 px**.
- Y maximum uses a rounded “nice” step with approximately four intervals.
- Horizontal grid lines: 1 px `hairline`.
- Y labels: 11 px, muted, tabular, positioned 8 px left of the plot.
- X labels: 11 px, muted, `MMM d`.
- Approximate X-label density: four divisions below a 520 px chart width, seven divisions otherwise.
- Labels too close to the Today marker are omitted.
- Today marker: faint vertical line, dash `2 3`, with an 11 px, 500-weight `Today` label.

### Series

For a single product in the prototype:

- Actual sales: solid `series-1` (`#57534E`), **1.75 px**, rounded joins.
- Predicted demand: `accent` (`#EA580C`), **2 px**, dash `5 4`, rounded joins.
- Likely range: orange area at 10% opacity, shown only for Calibrated Blend and LightGBM in prototype data.
- Legends appear below the chart with 12 px muted text:
  - Actual sales
  - Predicted demand
  - Likely range, only when present

The prototype constructs 28 historical + 7 forecast days for the 7-day horizon, and 56 historical + 28 forecast days for the 28-day horizon. These are prototype data-generation rules, not permission to synthesize missing Flutter history.

### Tooltip

Observed pointer-hover tooltip:

- Vertical hover line at the nearest date.
- A 3.5 px point with white fill and a 2 px series-colored border.
- Tooltip width **184 px**, at top **8 px**, with 1 px border, 8 px radius, 12 px padding horizontally and 8 px vertically, and medium shadow.
- Flips to the left after approximately 60% of the chart width to avoid overflow.
- Header: `EEE, MMM d · Actual` or `EEE, MMM d · Forecast`.
- Value: rounded quantity in 600 weight plus unit.
- Forecast range is shown when low/high values exist.
- No touch/keyboard tooltip behavior is implemented in the prototype; do not claim it as observed.

### Footer

- Top margin **12 px**.
- Left padding **44 px** at 640 px and above.
- Legend and right-side footer wrap.
- Prototype right footer contains `Simulated sales data` and `View forecast accuracy` with a right arrow.
- Flutter must show the simulation label only for synthetic/SIM data. `View forecast accuracy` may route to the existing Tracking & Accuracy view; it must not imply accuracy data exists when unavailable.

### Truthful Flutter fallback

The current `ForecastAnalysis` response exposes future `forecast.daily` points but not daily historical observations or confidence bounds. Therefore:

- Render the supported predicted-demand series and date/Y axes.
- Keep the explicit `Actual sales unavailable` legend/note.
- Do not draw a fake actual-sales series.
- Do not draw a likely-range area or period low/high text without API values.
- A tooltip may show future forecast date/value because those values exist.
- Do not show prior-period comparisons or an incomplete-history start date unless supported data is added to the client contract.

## 8. Recommendation component

The recommendation is always based on the existing preliminary **LightGBM 28-day** recommendation, independent of the selected chart model or horizon.

### Positive recommendation

- Inner highlight uses `accent-soft`, 8 px radius, **16 px** padding, and -4 px horizontal visual offset.
- Heading: `Preliminary suggested restock`.
- Quantity: 48 px, 600, accent-hover, tabular.
- Unit: 18 px, 500, body color.
- Supporting paragraph starts 12 px below and explains expected 28-day demand, current saleable stock, and the suggested difference.

### No suggestion yet

- Inner background is `page`.
- State title is `No suggestion yet`, 20 px/600.
- Explanation states that a quantity cannot be suggested because required demand/history information is unavailable.
- Flutter must use its existing precise missing-data/cold-start explanation, not assert “not enough sales history” for every null case.

### No restock suggested

- Inner background is `page`.
- State title is `No restock suggested`, 20 px/600.
- Explanation states that current saleable stock covers expected 28-day demand.

### Metrics

Below the highlight is a definition list starting **20 px** later, with top and row hairline dividers. Each row uses **10 px** vertical padding and a **16 px** gap:

- Saleable stock
- Expected demand, 28 days
- Current stock lasts (`floor(saleable / average daily predicted demand)`)

The optional prototype hint `{quantity} set aside as damaged` is unsupported by the current `InventoryItem`/`ForecastAnalysis` contract and must be omitted unless genuine data is available.

### Disclaimer

At the card bottom:

```text
Based on LightGBM’s 28-day forecast and saleable stock. Guidance only — nothing is ordered.
```

Use 12 px muted text with relaxed line height. Preserve the existing stronger safeguards that the estimate excludes supplier timing, incoming stock, backorders, safety stock, MOQ, and pack-size rules; requires owner review; and cannot create a purchase order or mutate inventory. These can remain as truthful notices below the prototype-aligned summary rather than being removed for visual fidelity.

No procurement, ordering, or purchase-order control belongs in this card.

## 9. Forecast limitations and metadata

### Important Forecast Limitations

Card styling:

- `caution-soft` background.
- 1 px `line` border plus **4 px** left `caution` border.
- 12 px radius.
- **16 px** vertical/horizontal padding, increasing to **20 px** horizontal from 640 px.
- Heading uses a 16 px `AlertTriangle`, 8 px icon/text gap, 14 px/600 caution-ink text.
- Bullet list begins 8 px below the heading, has 24 px left padding, 14 px relaxed text, and caution-colored markers.

Exact prototype general limitations:

1. `Predictions are estimates, not guaranteed sales.`
2. `Stockouts may cause recorded sales to understate true demand.`
3. `Promotions, local projects, or price changes may affect future demand.`
4. `Forecast reliability depends on available and accurate sales history.`

Flutter should retain API-provided warning text in addition to these general limitations.

### About this forecast

Card styling:

- White surface, 1 px line border, 12 px radius.
- **16 px** padding, increasing to **20 px horizontal** from 640 px.
- Heading: 14 px/600.
- Definition list begins 4 px below, uses 1 px hairline row dividers, and 8 px vertical row padding.
- Labels are muted and fixed-width; values truncate, right-align, and use ink.

Prototype rows:

- Sales history
- Data quality
- Seasonal pattern

Prototype values are derived from simulated fields and must not be copied. Flutter mappings are:

- Sales history: use parsed history coverage if exposed; otherwise `Not exposed by this response`.
- Data quality: use cold-start reason and warnings. The raw backend response also contains history/observed/assumed-zero/stockout/availability counts, but the current Dart `ForecastSummary` does not parse them.
- Seasonal pattern: use `seasonalContext.seasonalRelevance` plus `evidenceLevel` when present; otherwise `Not available for this forecast method`.
- Preserve `sourceDataAsOf` and synthetic/SIM/live provenance, even though they are additional to the three-row prototype.

The current Technical Model Details disclosure is not present in the approved prototype. Do not delete its model version, provenance, execution source, generated/source timestamps, or seasonal transition evidence. Either retain the disclosure beneath the chart or move these fields into an explicitly secondary metadata disclosure; do not crowd the three primary About rows.

## 10. Flutter component mapping

| Approved Product Forecast component | Existing Flutter component/state | Required implementation change |
|---|---|---|
| Product page composition | `_buildProductForecastView` | Keep current page state/API load path; align gaps and card placement to prototype only. |
| Product selector trigger | `_buildProductControls` | Existing name, metadata, count, and adjacent controls are close. Match trigger/menu styling and remove no functionality. |
| Searchable anchored menu | `_ProductPickerDialog` | Current search works but opens a modal dialog. Replace presentation with a 352 px anchored menu while reusing `_selectedProductId` and `_selectProduct`. |
| Previous/next product | `_ProductStepButton`, `_selectAdjacentProduct` | Already circular and functional; match 32 px bordered Lucide-button styling. |
| Product metadata | `_buildProductControls`, `InventoryItem`, `PreliminaryRestockingInsight.availableInventory` | Match order/wrapping. Continue truthful `saleable` wording where applicable. |
| 2:1 desktop primary grid | `ForecastAnalysisPanel` `LayoutBuilder` | Existing 2:1 row starts at 960 px; approved breakpoint is 1024 px. Use 24 px gap and stack below breakpoint. |
| Forecast card | `_ForecastCard` | Existing border/radius/card structure is close. Match 16/24 px responsive padding and chart heading text. |
| Today/7/28 strip | `_ProductPeriodStrip`, `_ProductPeriodCell` | Existing layout stacks below 620 px and lacks selected underline/ranges. Use 640 px breakpoint and selected 2 px accent bar. Do not invent ranges. |
| Forecast method menu | `_buildCompactModelSelector`; rich `_ForecastMethodMenu` exists for Overview | Product uses a basic dropdown. Reuse/adapt the rich menu visual and descriptions, preserving Product Forecast state and Flutter model IDs. |
| Demand chart | `_PrimaryForecastChart`, `_DemandSparklinePainter` | Upgrade supported forecast rendering to axes/dates/hover forecast values. Keep actual-sales-unavailable fallback; no fake actual/range series. |
| View forecast accuracy | Existing `_selectedView = tracking` path from Overview; Product card currently lacks link | Add only as navigation to Tracking & Accuracy, using existing view state; disable/qualify if no accuracy records exist. |
| Preliminary recommendation | `_RecommendationCard` | Already uses `PreliminaryRestockingInsight` and correct LightGBM separation. Tighten styling/hierarchy to `RestockPanel` while retaining safeguards. |
| Important Forecast Limitations | `_ProductForecastContext` | Existing disclosure logic is close. Add the two prototype expanded general limitations and retain API warnings; count dynamically. |
| About this forecast | `_ProductForecastContext` | Existing truthful fallbacks are stronger than prototype demo values. Match compact definition-list styling and retain source/provenance. |
| Technical provenance | `_ForecastTechnicalDetails`, `ForecastSummary`, `SeasonalForecastContext` | Not in prototype, but required to preserve provenance. Keep as secondary disclosure; do not remove or fabricate. |
| Loading/error/cold-start notices | `ForecastAnalysisPanel` | Not represented in the default prototype. Preserve them as required truthful operational states. |

## 11. Unsupported prototype features

The following prototype visuals are not supported by the current Flutter data contract and must use truthful fallbacks:

| Prototype element | Current support | Required fallback |
|---|---|---|
| Daily historical actual-sales series | Not returned in `ForecastAnalysis`; prototype generates it locally | Do not draw. Show `Actual sales unavailable` and forecast-only disclosure. |
| Actual value in chart tooltip | No daily actual values | Forecast tooltip only. |
| Likely-range chart area | No daily low/high interval fields | Omit area and legend. |
| `Likely X–Y` in period cells | No aggregate low/high interval fields | Leave range line blank or show supported status text only. |
| Exact sales-history start date | Not parsed/provided as a date | Use `Not exposed by this response`. |
| Prior-period percentage comparison | No prior daily series in analysis response | Omit. |
| `set aside as damaged` quantity | No unsaleable breakdown in current InventoryItem/analysis models | Omit hint; continue using API saleable stock. |
| Literal `Today` estimate | Future forecast dates may not include the local current date | Use `Today` only if a forecast point matches the current Manila business date; otherwise label the first supported forecast date truthfully. |
| Prototype demo/simulation labels on all products | Only valid for `analysis.synthetic` or SIM SKU | Display conditionally; never label live data as simulated. |

The raw backend forecast response contains data-quality counts (`history_calendar_days`, `observed_sales_days`, `assumed_zero_sales_days`, `stockout_censored_days`, and `availability_unknown_days`), but the current Dart model retains only warnings. Exposing those existing response fields would be a client-model change, not new backend functionality. It is optional for visual implementation and must not block the truthful fallback.

## 12. Visual acceptance checklist

### Reference and scope

- [ ] Implementation is based on `afcadf46-bf75-4c82-9a54-fea343d60e49.zip`, not an older export.
- [ ] Only Product Forecast presentation changes.
- [ ] Existing Forecasting title/tab navigation is reused, not duplicated.

### Product selector

- [ ] Product name truncates without displacing controls.
- [ ] Menu is anchored, searchable by name/SKU/category, and capped to the viewport.
- [ ] Selected option, empty result, outside-click, and Escape states work.
- [ ] Previous/next controls wrap and select the correct live product.
- [ ] Category, SKU, unit, and truthful stock metadata wrap correctly.

### Layout

- [ ] At >=1024 px, forecast and recommendation are 2:1 with a 24 px gap.
- [ ] Below 1024 px, forecast precedes recommendation in one column.
- [ ] At >=768 px, limitations and About use two equal columns.
- [ ] Below 768 px, limitations precede About in one column.
- [ ] Cards use white surfaces, 1 px borders, 12 px radii, and no unnecessary shadows.

### Forecast card

- [ ] Today, Short-term, and Planning summaries occupy the same card header.
- [ ] At >=640 px, all three summaries are one row; below it they stack.
- [ ] Selected 7/28 period has subtle fill and a 2 px orange bottom indicator.
- [ ] Method selector shows all four live models, descriptions, and tags.
- [ ] Method changes reload/update only supported forecast data; preliminary recommendation remains LightGBM-based.

### Chart

- [ ] Chart is 260 px high with the specified padding, grid, date/Y labels, and Today marker where applicable.
- [ ] Predicted demand uses an orange dashed line.
- [ ] No historical actual line or likely range is fabricated.
- [ ] Forecast tooltip uses real dates/values only.
- [ ] Legend explicitly states actual sales are unavailable when absent.
- [ ] Synthetic/SIM and accuracy links are truthful and conditional.

### Recommendation

- [ ] Positive, zero, and unavailable recommendation states match the specified hierarchy.
- [ ] Quantity and unit come from `PreliminaryRestockingInsight`.
- [ ] Saleable stock, 28-day expected demand, and cover days use existing values/formula.
- [ ] Guidance remains read-only and explicitly does not order or mutate inventory.
- [ ] Existing owner-review and missing-input safeguards remain visible.

### Limitations and metadata

- [ ] Two general limitations are visible by default.
- [ ] Remaining general limitations and API warnings expand/collapse with an accurate count.
- [ ] About rows use truthful history, quality, and seasonal evidence values/fallbacks.
- [ ] Model/version, source timestamps, provenance, and seasonal evidence are preserved in secondary metadata.
- [ ] No prototype sample products, quantities, confidence intervals, history, or dates are hardcoded.

