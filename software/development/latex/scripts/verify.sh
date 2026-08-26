#!/usr/bin/env bash
# Description: Post-install acceptance test for the latex module — checks the
#              engine and latexmk run, that every style file the install set
#              promises is resolvable, and that a document using all of them
#              actually compiles to a PDF. Tests capability, not provenance.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: pdflatex, latexmk, kpsewhich (installed by install.sh)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

fails=0
check() {
  # check "<label>" <command...>
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_error "$label"
    fails=$((fails + 1))
  fi
}

# Checks target capability, never package names. A working LaTeX toolchain can
# legitimately arrive from the Ubuntu archive (what install.sh does), from
# upstream TeX Live via the install-tl installer, or from a vendor image —
# asserting on dpkg package names would fail a perfectly good machine.

log_info "Verifying LaTeX install..."

# 1. The engine and the build driver are present and run.
check "pdflatex on PATH"    command -v pdflatex
check "pdflatex --version runs" pdflatex --version
check "latexmk on PATH"     command -v latexmk
check "latexmk --version runs"  latexmk --version
check "kpsewhich on PATH"   command -v kpsewhich

# 2. Every style file the install set exists to provide is resolvable. This is
#    the set actually used by the documents this module was added for, and it
#    spans all five packages, so a partial install shows up here rather than as
#    a mystery failure inside someone's build months later.
for sty in array booktabs enumitem fancyhdr float fontenc \
           geometry graphicx hyperref lmodern longtable ragged2e; do
  check "kpsewhich resolves $sty.sty" kpsewhich "$sty.sty"
done

# 3. The check that actually matters: does a document using all of the above
#    compile to a PDF? Everything before this can pass on a toolchain whose
#    formats are unbuilt or whose font maps are broken.
smoke_test() {
  local tmp pdf
  tmp="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  cat > "$tmp/smoke.tex" <<'EOF'
\documentclass[11pt]{article}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage[letterpaper,margin=1in]{geometry}
\usepackage{array}
\usepackage{booktabs}
\usepackage{enumitem}
\usepackage{fancyhdr}
\usepackage{float}
\usepackage{graphicx}
\usepackage{longtable}
\usepackage{ragged2e}
\usepackage[hidelinks]{hyperref}
\pagestyle{fancy}
\begin{document}
\section{Smoke test}
\begin{itemize}[nosep]\item \RaggedRight one \item two\end{itemize}
\begin{tabular}{@{}ll@{}}\toprule a & b \\ \midrule c & d \\ \bottomrule\end{tabular}
\begin{longtable}{ll} e & f \\ \end{longtable}
\href{https://example.invalid}{link}
\resizebox{1cm}{!}{scaled}
\end{document}
EOF

  ( cd "$tmp" && pdflatex -interaction=nonstopmode -halt-on-error smoke.tex ) || return 1
  pdf="$tmp/smoke.pdf"
  [ -s "$pdf" ] || return 1
}
check "a document using all of them compiles to a PDF" smoke_test

echo

# Informational only — provenance, not a pass/fail criterion.
if dpkg -s texlive-latex-extra &>/dev/null; then
  log_info "Provenance: Ubuntu archive texlive-* packages (what install.sh uses)."
else
  log_info "Provenance: no texlive-latex-extra package — this toolchain came from"
  log_info "  somewhere other than the Ubuntu archive. Both are supported."
fi

if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. Versions:"
  pdflatex --version 2>/dev/null | head -1
  latexmk --version 2>/dev/null | head -1
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "If a kpsewhich check failed, a package in the install set is missing:"
  log_warn "  bash $SCRIPT_DIR/install.sh"
  log_warn "If only the compile failed, the packages are present but the toolchain"
  log_warn "is broken — rebuild the formats and font maps:"
  log_warn "  sudo fmtutil-sys --all && sudo updmap-sys"
  exit 1
fi
