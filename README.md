# quarto-study-flow

A Quarto shortcode extension that renders **CONSORT**, **STROBE**, and
**PRISMA 2020** participant-flow diagrams from structured YAML declared in the
document frontmatter.

- Pure Lua. No `graphviz`, no `rsvg-convert`, no shell-outs, no Python — zero
  external dependencies.
- HTML output: inline SVG.
- PDF / LaTeX output: native TikZ (so it works with any LaTeX engine without
  needing `librsvg` or Inkscape).

## Installation

Place the extension in your project's `_extensions/` directory:

```text
your-project/
├── _extensions/
│   └── study-flow/
│       ├── _extension.yml
│       └── study-flow.lua
└── your-document.qmd
```

Or, from the root of a Quarto project:

```bash
quarto add tiagojct/quarto-study-flow
```

## Usage

Declare the diagram in YAML frontmatter under the `study-flow` key, then drop
the shortcode `{{< study-flow >}}` wherever you want the figure to appear.

### CONSORT

```yaml
---
study-flow:
  type: consort
  enrollment:
    assessed: 350
    excluded: 120
    exclusion_reasons:
      - "Did not meet inclusion criteria: 80"
      - "Declined to participate: 40"
  randomised: 230
  groups:
    - label: "Intervention"
      allocated: 115
      received: 110           # optional
      lost_followup: 8
      lost_reasons:
        - "Withdrew consent: 5"
        - "Lost to follow-up: 3"
      analysed: 107
      excluded_analysis: 3    # optional
      excluded_analysis_reasons:
        - "Protocol deviation: 3"
    - label: "Control"
      allocated: 115
      lost_followup: 10
      analysed: 105
---

{{< study-flow >}}
```

The CONSORT layout follows the four canonical rows from the CONSORT 2010
statement: **Enrolment → Allocation → Follow-up → Analysis**, with a side
arrow from Enrolment to the *Excluded* box, and N parallel columns (one per
arm) under *Randomised*.

### STROBE

```yaml
---
study-flow:
  type: strobe
  source:
    label: "Source population"
    n: 12500
  eligible:
    label: "Eligible cohort"
    n: 8400
    excluded: 4100
    exclusion_reasons:
      - "Outside age range: 2600"
      - "Insufficient follow-up: 1100"
  enrolled:
    n: 7200
    excluded: 1200
  groups:
    - label: "Exposed"
      n: 3100
      lost_followup: 220
      analysed: 2880
    - label: "Unexposed"
      n: 4100
      lost_followup: 310
      analysed: 3790
---
```

The STROBE flow runs **Source → Eligible → Enrolled** as a vertical spine,
each stage with an optional *Excluded* sidebar. Below the spine the diagram
splits into N exposure / case-control columns with optional follow-up loss
and analysis rows, mirroring how cohort flow is conventionally drawn under
the STROBE statement.

`source`, `eligible`, `enrolled`, and `groups` are all individually optional —
omit any stage you don't need. At least one stage or group is required.

### PRISMA 2020

```yaml
---
study-flow:
  type: prisma
  identification:
    databases: 1842
    registers: 167
    duplicates_removed: 612
    ineligible_automation: 88
    other_removed: 14
  screening:
    screened: 1295
    excluded: 1024
    sought_retrieval: 271
    not_retrieved: 23
    assessed: 248
    excluded_with_reasons:
      - "Wrong population (n=46)"
      - "Wrong intervention (n=31)"
      - "Wrong outcome (n=22)"
  included:
    studies: 120
    reports: 134
---
```

The PRISMA layout follows the canonical PRISMA 2020 flow, with five rows on
the main spine —
**Records identified → Records screened → Reports sought → Reports assessed →
Studies included** — and *Excluded* / *Removed* boxes branching to the right
at each step. Any field you omit collapses the corresponding box.

## Output formats

| Format        | Renderer | Notes                                       |
| ------------- | -------- | ------------------------------------------- |
| `html`        | inline SVG | Scales to container; `text-anchor="middle"`. |
| `revealjs`    | inline SVG |                                              |
| `pdf` / `latex` | TikZ   | Auto-loads `tikz`, `graphicx`, `arrows.meta`. Wrapped in `\resizebox{\linewidth}{!}{...}` so it always fits the text width. |
| Other         | inline SVG (fallback) |                                |

The TikZ backend uses pixel-equivalent coordinates with `[x=1pt, y=-1pt]`
internally. Because the picture is scaled to `\linewidth`, you don't need
to tune sizes for the page geometry.

## Examples

This repository contains:

- `example-consort.qmd`
- `example-strobe.qmd`
- `example-prisma.qmd`

Render any of them with:

```bash
quarto render example-consort.qmd --to html
quarto render example-consort.qmd --to pdf
```

## Field reference

### CONSORT

```
type: consort
enrollment:
  assessed:           number   # required
  excluded:           number   # required
  exclusion_reasons:  [string] # optional
randomised:           number   # required
groups:                        # required, 1+ entries
  - label:                       string  # required
    allocated:                   number  # required
    received:                    number  # optional
    not_received:                number  # optional
    lost_followup:               number  # optional (defaults to 0)
    lost_reasons:                [string]
    discontinued:                number  # optional
    discontinued_reasons:        [string]
    analysed:                    number  # required
    excluded_analysis:           number  # optional
    excluded_analysis_reasons:   [string]
```

### STROBE

```
type: strobe
source:    { label: string, n: number }                       # optional
eligible:  { label: string, n: number,
             excluded: number, exclusion_reasons: [string] }  # optional
enrolled:  { label: string, n: number,
             excluded: number, exclusion_reasons: [string] }  # optional
groups:                                                       # optional
  - label:         string
    n:             number
    lost_followup: number          # optional
    lost_reasons:  [string]
    analysed:      number
    excluded_analysis: number      # optional
    excluded_analysis_reasons: [string]
```

### PRISMA

```
type: prisma
identification:
  databases:              number
  registers:              number   # optional
  duplicates_removed:     number   # optional
  ineligible_automation:  number   # optional
  other_removed:          number   # optional
screening:
  screened:               number   # optional
  excluded:               number   # optional (sidebar to screened)
  sought_retrieval:       number   # optional
  not_retrieved:          number   # optional (sidebar to sought_retrieval)
  assessed:               number   # optional
  excluded_with_reasons:  [string] # optional (sidebar to assessed)
included:
  studies:                number   # optional
  reports:                number   # optional
```

## License

MIT
