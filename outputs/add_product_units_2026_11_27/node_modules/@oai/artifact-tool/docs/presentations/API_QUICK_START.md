# Presentation Quick Start (TypeScript)

## API Docs

API docs: `api/API_DOCS.md`

`Presentation` represents a deck. A slide is one page.
Object examples assume an existing `presentation`, `slide`, `shape`, or `chart`.

## Text formatting

Geometry and numeric `fontSize` use CSS pixels at 96 DPI. For a size in points,
include the unit, for example `"17pt"`. When matching a template, keep its sizes.

Assign a config to `shape.text.style` to set several fields. Read or edit
individual fields on `shape.text`:

```js
shape.text.style = { fontSize: "17pt", color: "#123456", bold: true };
shape.text.color = "#2563eb";
```

Reading `shape.text.style` returns a style name or `undefined`, not a config.
See [rich text](api/references/rich-text.spec.md#shape-text-style) for fields and types.

## Images and previews

Linked images expose `asset.uri`. Embedded images may omit it.
[Replace an image](api/references/images.spec.md#replace-source) with `path` or `blob`.
[`render()`](api/references/presentation.spec.md) previews all slides. Raster `export()` defaults to the active slide.

## Find and edit content

- Name elements explicitly, such as `"headline"`. Avoid lookups based on guessed
  `text.slice(0,32)` names. Text edits can leave names unchanged.
- Inspect current names, text, and IDs. Confirm the intended match before editing.
- Use current inspect IDs for `resolve`/`delete`. Create slides with raw layout
  IDs or exact layout names. Preview slides with zero-based indexes.
- Use canonical slide IDs such as `sl/abcdefgh` for `presentation.delete` and
  `presentation.slides.reorder`. Reordering needs every current slide ID exactly once.

`presentation.inspect({ select, include })` uses RFC 9535 JSONPath functions,
not JavaScript methods. Use equality for literal text. Legacy `search` interprets
regex characters such as `$`. See [inspection](api/references/inspect.md#find-and-edit).

```js
const text = "Cost: $5";
await presentation.inspect({
  select: "$.slides[*].elements[?(@.text == " + JSON.stringify(text) + ")]",
  include: ["id", "name", "text"],
});
```

### Artifact Session

An Artifact Session lets you create a presentation and edit it across multiple calls.
The host application starts or connects to the session service and provides the
`artifactSession` client in its JavaScript REPL. The first argument to
`artifactSession.run` is a callback. It runs in the REPL with the current
`presentation`.

Use `create: true` to start a new deck. This callback adds a slide with a
text box named `headline`.

```js
const deck = await artifactSession.run(
  async ({ presentation }) => {
    const slide = presentation.slides.add();
    const headline = slide.shapes.add({
      name: "headline",
      geometry: "textbox",
      position: { left: 40, top: 40, width: 640, height: 80 },
    });
    headline.text = "Quarterly results";
  },
  { artifactType: "presentation", create: true, title: "Quarterly review" },
);
```

To edit that deck in a later call, use the `artifactRef` returned by the
first run. This callback updates the headline on the first slide.

```js
await artifactSession.run(
  async ({ presentation }) => {
    const shapes = presentation.slides.items[0].shapes.items;
    const matches = shapes.filter(shape => shape.name === "headline");
    if (matches.length !== 1) throw new Error("Expected one headline on slide 0");
    matches[0].text = "Quarterly update";
  },
  { artifactRef: deck.artifactRef },
);
```

The host saves successful edits to the deck. In later callbacks, look up the
slide or shape again. Render a slide to check an edit, or export to PPTX for a
file copy.

## Collections and chart edits

- Use `.items` for array methods, `chart.series.getItemAt(index)` for a series,
  and `presentation.slides.getItem(index)` for a slide.
- Style a point by data index with `series.apply`. Add label overrides with
  `series.dataLabelOverrides.add(index)`. Assign a config to `series.marker`
  or `chart.xAxis.textStyle`. See [chart editing](api/references/charts.spec.md).
- Combo charts take series through `groups`, with at least one primary-axis
  group. See [combo charts](api/references/charts.spec.md#combo-charts).

```js
const seriesNames = chart.series.items.map((series) => series.name);
const firstSeries = chart.series.getItemAt(0);
firstSeries.apply({ name: firstSeries.name, points: [{ idx: 0, fill: "#2563eb" }] });
firstSeries.marker = { symbol: "circle", size: 8 };
firstSeries.dataLabelOverrides.add(0).showValue = true;
chart.xAxis.textStyle = { fontSize: "17pt", bold: true };
```

```js
// Place labels outside the bars in this example.
chart.dataLabels = { showValue: true, position: "outEnd" };

// Override one label to place it inside its bar.
const label = chart.series.getItemAt(0).dataLabelOverrides.add(0);
label.showValue = true;
label.position = "inEnd";
```

## Custom shapes and connectors

Supply custom paths in the same `shapes.add` call. See
[custom paths](api/references/shapes.spec.md#custom-path) and
[connector bounds](api/references/connectors.md#unattached-connector).

## PPTX quick start examples

These examples create and edit a local `.pptx` in `.presentation-draft/`.
Choose a directory that suits your task. To edit an open deck in place, see
[Artifact Session](#artifact-session).

### Create, render, export

Create an editable deck, render each slide as a PNG, and export a draft PPTX.

```js
import fs from "node:fs/promises";
import { Presentation, PresentationFile } from "@oai/artifact-tool";

async function writeBlob(path, blob) {
  await fs.writeFile(path, new Uint8Array(await blob.arrayBuffer()));
}

async function main() {
  const draftDir = ".presentation-draft";
  await fs.mkdir(draftDir, { recursive: true });

  const presentation = Presentation.create({
    slideSize: { width: 1280, height: 720 },
  });

  const slide = presentation.slides.add();
  slide.background.fill = "slate-50";

  // Every coordinate has a field name: left, top, width, and height.
  const page = { left: 72, top: 64, width: 1136, height: 592 };
  const gutter = 28;
  const leftCol = 430;
  const rightCol = page.width - leftCol - gutter;

  const title = slide.shapes.add({
    geometry: "textbox",
    position: {
      left: page.left,
      top: page.top + 92,
      width: leftCol,
      height: 184,
    },
    fill: "none",
    line: { style: "solid", fill: "none", width: 0 },
  });
  title.text = "Customer growth";
  title.text.style = { fontSize: "32pt", bold: true, color: "slate-950" };

  const subtitle = slide.shapes.add({
    geometry: "textbox",
    position: {
      left: page.left,
      top: page.top + 292,
      width: leftCol,
      height: 96,
    },
    fill: "none",
    line: { style: "solid", fill: "none", width: 0 },
  });
  subtitle.text = "Quarterly active customers, thousands.";
  subtitle.text.style = { fontSize: "17pt", color: "slate-600" };

  slide.charts.add("bar", {
    position: {
      left: page.left + leftCol + gutter,
      top: page.top + 92,
      width: rightCol,
      height: 280,
    },
    categories: ["Q1", "Q2", "Q3"],
    series: [{ name: "Customers", values: [3, 4, 5], fill: "accent1" }],
    hasLegend: false,
    dataLabels: { showValue: true, position: "outEnd", textStyle: { fontSize: "17pt" } },
    xAxis: { textStyle: { fontSize: "17pt" } },
    yAxis: {
      textStyle: { fontSize: "17pt" },
      majorGridlines: { style: "solid", fill: "slate-200", width: 1 },
    },
  });

  for (const [index, renderedSlide] of presentation.slides.items.entries()) {
    const stem = `slide-${String(index + 1).padStart(2, "0")}`;
    const png = await presentation.export({ slide: renderedSlide, format: "png", scale: 1 });
    await writeBlob(`${draftDir}/${stem}.png`, png);
  }

  const pptx = await PresentationFile.exportPptx(presentation);
  await pptx.save(`${draftDir}/deck.pptx`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

Use [inspection exports](#inspection-exports) for layout JSON and a deck montage.

Every line config requires `style`, including invisible lines such as
`{ style: "solid", fill: "none", width: 0 }`. Check the installed runtime's
docs for accepted fields before adapting a config from another library.

### Import and edit PPTX

This example expects one matching title. If several slides share the title,
narrow the search to the intended slide. If none match, inspect the slide's text.

```js
import fs from "node:fs/promises";
import { FileBlob, PresentationFile } from "@oai/artifact-tool";

const dir = ".presentation-draft";
const presentation = await PresentationFile.importPptx(
  await FileBlob.load(`${dir}/deck.pptx`),
);
const before = await presentation.inspect({
  select: "$.slides[*]",
  include: ["id", "elements.id", "elements.kind", "elements.text"],
});
const title = "Customer growth";
const matches = before.records.flatMap((slide) =>
  (slide.elements ?? [])
    .filter((el) => el.kind === "textbox" && el.text === title)
    .map((el) => ({ slideId: slide.id, shapeId: el.id })),
);
if (matches.length !== 1) throw new Error(`Expected one title, found ${matches.length}`);

const { slideId, shapeId } = matches[0];
const slide = presentation.resolve(slideId);
async function savePreview(name) {
  const png = await presentation.export({ slide, format: "png" });
  await fs.writeFile(`${dir}/${name}.png`, new Uint8Array(await png.arrayBuffer()));
}

await savePreview("before-slide");
presentation.resolve(shapeId).text.replace(title, "Quarterly customer growth");
await savePreview("after-slide");

const pptx = await PresentationFile.exportPptx(presentation);
await pptx.save(`${dir}/edited-deck.pptx`);
```

### Inspection exports

With the `slide`, `presentation`, and `dir` from the edit example, save the slide layout.

```js
const layout = await slide.export({ format: "layout" });
await fs.writeFile(`${dir}/slide.layout.json`, await layout.text());
```

Render a montage to compare slides.

```js
const montage = await presentation.export({
  format: "webp",
  montage: true,
});
await fs.writeFile(`${dir}/deck-montage.webp`, new Uint8Array(await montage.arrayBuffer()));
```

### Embedded image bytes

This embeds the PNG in the PPTX. Artifact Tool 2.8.113 keeps the alt text in memory
but omits it from the exported file.

```js
async function readImageBlob(imagePath) {
  const bytes = await fs.readFile(imagePath);
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  );
}

const imageBytes = await readImageBlob("assets/product.png");
slide.images.add({
  blob: imageBytes,
  contentType: "image/png",
  alt: "Product screenshot",
  fit: "contain",
  position: { left: 720, top: 96, width: 420, height: 280 },
});
```

## References

Pass a query string first to `presentation.help`, then its options:
`presentation.help("chart", { include: ["examples", "notes"] })`.

Use the [API reference map](api/API_DOCS.md#reference-map) to choose a reference.

| Task | References |
| --- | --- |
| Decks and slides | [Presentation](api/references/presentation.spec.md), [slides](api/references/slide.spec.md), [masters](api/references/master.spec.md), [layouts](api/references/layout.spec.md), [themes](api/references/theme.spec.md) |
| Shapes and text | [Shapes](api/references/shapes.spec.md), [connectors](api/references/connectors.md), [fills and lines](api/references/fill.spec.md), [rich text](api/references/rich-text.spec.md), [named styles](api/references/styles.spec.md) |
| Data and images | [Charts](api/references/charts.spec.md), [tables](api/references/tables.spec.md), [images](api/references/images.spec.md) |
| Finding and editing content | [Inspection](api/references/inspect.md), [inspection schema](api/references/inspect.schema.json), [API help](api/references/help.md), [imported deck editing](api/references/cookbook/imported-deck.md) |
| Composition | [Tokens](api/references/tokens.md), [layout recipes](api/references/cookbook/layout.md), [auto layout](api/references/auto-layout.spec.md) |
| Notes and review | [Speaker notes](api/references/speaker-notes.spec.md), [comments](api/references/comments.md) |
