# LaTeX (TeX Live)

> **Profiles:** `[dev]` `[workstation]` `[workplace]`
> **Platforms:** ubuntu-24.04 (primary)

A LaTeX toolchain for building article-class documents — reports, proposals,
specifications — to PDF with `pdflatex`, driven by `latexmk`. Installed from the
**Ubuntu archive**, so it updates through normal `apt upgrade` and needs no
third-party repository or keyring.

## Why this category

`software/development/` alongside `claude-code` and `docker`. LaTeX here is a
build toolchain, not an end-user application: it is invoked from the command
line and from editors, it produces artifacts from source files kept in git, and
it is provisioned exactly like the other dev tooling. A `documents/` category
holding one module would fragment the tree without making anything easier to
find.

## Why not `texlive-full`

`texlive-full` is on the order of 5 GB and pulls in the entire TeX Live
distribution — every language's hyphenation patterns, every journal's document
class, ConTeXt, XeTeX, LuaTeX, BibTeX variants and the full font collection.
The install set here is four headline packages plus one font package:

| Package | What it provides |
|---|---|
| `texlive-latex-recommended` | The LaTeX packages most documents actually use (`booktabs`, `float`, `ragged2e`, …); pulls in `texlive-latex-base` |
| `texlive-fonts-recommended` | The standard font set |
| `texlive-latex-extra` | The long tail (`enumitem`, …); pulls in `texlive-pictures` |
| `latexmk` | The build driver — reruns the engine until cross-references settle |
| `lmodern` | Latin Modern — see below |

That is enough for article-class documents using `booktabs`, `hyperref`,
`geometry` and `enumitem`, which is the shape of the documents this repo's owner
writes. It costs roughly 400 packages and a bit over 1 GB unpacked, against
`texlive-full`'s several thousand.

**`pdflatex` only.** `xelatex` and system-font support are *not* installed
(`texlive-xetex` is absent from the set). Add it deliberately if a document ever
needs `fontspec`.

### Why `lmodern` is named explicitly

It looks redundant — and under apt's default settings it is, because
`texlive-base` *recommends* `lmodern` and recommends are installed by default.
It is not redundant under `--no-install-recommends`: there the four headline
packages pull in `fonts-lmodern`, which ships the font files, but **not**
`lmodern`, which is what ships `lmodern.sty`. `\usepackage{lmodern}` then fails
with a missing-file error while a package whose name contains "lmodern" is
plainly installed, which is a genuinely confusing half-hour. Naming it makes the
set self-sufficient under either apt policy.

Measured in a clean `ubuntu:24.04` container: the four headline packages resolve
to 375 packages with recommends on (`lmodern` among them) and 79 with
`--no-install-recommends` (`lmodern` absent, `fonts-lmodern` present).

## Install

```bash
bash scripts/install.sh
```

Idempotent: it checks each package with `dpkg -s` first and skips apt entirely
when the whole set is present. This is a large download on a fresh machine — the
script says so before it starts.

## Verify

```bash
bash scripts/verify.sh
```

Three tiers, all testing capability rather than which package supplied it:

1. `pdflatex`, `latexmk` and `kpsewhich` are on PATH and run.
2. `kpsewhich` resolves each of the twelve style files the install set exists to
   provide — `array`, `booktabs`, `enumitem`, `fancyhdr`, `float`, `fontenc`,
   `geometry`, `graphicx`, `hyperref`, `lmodern`, `longtable`, `ragged2e`.
3. A document that `\usepackage`s all twelve is compiled to a PDF in a
   temporary directory, which is then removed. This is the check that matters:
   the first two tiers pass on a toolchain whose formats are unbuilt or whose
   font maps are broken.

Manual equivalents:

```bash
pdflatex --version
latexmk --version
kpsewhich booktabs.sty          # /usr/share/texlive/texmf-dist/tex/latex/booktabs/booktabs.sty
```

## Uninstall

```bash
bash scripts/uninstall.sh          # dry run — prints the plan, changes nothing
bash scripts/uninstall.sh --yes    # actually remove
```

Removes the five packages plus whatever `apt-get autoremove` finds orphaned.
Never touches `.tex`, `.bib` or built `.pdf` files anywhere on disk, and never
touches `~/texmf`.

> **Read the dry run before using `--yes`.** A LaTeX toolchain is rarely used
> only by whoever installed it: pandoc's PDF output, matplotlib's `usetex` mode,
> R's Sweave/knitr and doxygen's PDF manuals all shell out to `pdflatex` and
> break silently once it is gone. `apt-cache rdepends --installed
> texlive-latex-recommended` shows what else is attached. Your documents
> survive; the ability to build them does not.

## Usage

```bash
latexmk -pdf report.tex     # build, rerunning until cross-references settle
latexmk -pdf -pvc report.tex   # rebuild continuously as you edit
latexmk -C                  # clean all generated files, including the PDF
```

`latexmk` is preferred over calling `pdflatex` by hand because it works out how
many passes a document needs — `hyperref` and `longtable` both require at least
two, and a single-pass build silently emits stale page numbers and `??`
cross-references.

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Standard install. Ships TeX Live 2023 (`texlive-base 2023.20240207-1`). |

## Troubleshooting

- **`LaTeX Error: File 'x.sty' not found`** → the style is outside this install
  set. Find its package with `apt-file search x.sty`, then install that package
  rather than widening this module, unless it is broadly useful.
- **`\usepackage{lmodern}` fails but `fonts-lmodern` is installed** → the
  machine was provisioned with `--no-install-recommends`. `sudo apt-get install
  lmodern`, or re-run `install.sh`, which names it.
- **Cross-references show `??` or page numbers are stale** → the document needs
  another pass. Use `latexmk -pdf`, not a bare `pdflatex`.
- **Everything is installed but nothing compiles** → the formats or font maps
  are broken. `sudo fmtutil-sys --all && sudo updmap-sys`.
