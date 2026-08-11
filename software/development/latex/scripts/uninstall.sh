#!/usr/bin/env bash
# Description: Removes the LaTeX toolchain this module installs and anything
#              left orphaned by it. Dry run by default; --yes to proceed.
#              NEVER removes .tex/.bib sources, built PDFs, or ~/texmf.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: apt, dpkg (toolchain installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

# The set install.sh names. Dependencies these dragged in (texlive-base,
# texlive-latex-base, texlive-binaries, texlive-pictures, texlive-plain-generic,
# fonts-lmodern, tex-common) are deliberately NOT listed: apt-get autoremove
# collects the ones that end up orphaned, and leaves the ones something else
# still needs. Naming them here would remove them out from under that other
# software.
LATEX_PKGS=(
  texlive-latex-recommended
  texlive-fonts-recommended
  texlive-latex-extra
  latexmk
  lmodern
)

installed_pkgs=()
for pkg in "${LATEX_PKGS[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    installed_pkgs+=("$pkg")
  fi
done

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "LaTeX uninstall would REMOVE:"
if [ "${#installed_pkgs[@]}" -eq 0 ]; then
  plan "(no LaTeX packages from this module are installed — nothing to remove)"
else
  plan "apt packages: ${installed_pkgs[*]}"
  plan "any packages left orphaned by the above (via apt-get autoremove) —"
  plan "  typically texlive-base, texlive-latex-base, texlive-binaries,"
  plan "  texlive-pictures, texlive-plain-generic, fonts-lmodern, tex-common"
fi

log_info "and would deliberately KEEP:"
keep "every .tex, .bib, .cls, .sty and built .pdf anywhere on disk — user data"
keep "~/texmf — your personal TeX tree of hand-installed classes and styles"
keep "~/.texlive* and ~/.cache/texmf — user-level font and format caches"
keep "ghostscript, ImageMagick, python3 and other general-purpose tools that"
keep "  came along as dependencies — other software depends on them"

# The equivalent of the perf-dashboard power-profiles-daemon disclosure: this
# module's removal set is wide, and detection is content-based (whatever
# dpkg -s finds), so it cannot tell "installed for this module" from
# "installed for something else".
if [ "${#installed_pkgs[@]}" -gt 0 ]; then
  log_warn "A LaTeX toolchain is rarely used only by the person who installed it."
  log_warn "pandoc's PDF output, matplotlib's usetex mode, R's Sweave/knitr,"
  log_warn "doxygen's PDF manuals and many editor plugins all shell out to"
  log_warn "pdflatex and will break silently once it is gone. apt-get remove"
  log_warn "pulls the reverse-dependency chain non-interactively, so check"
  log_warn "what else is attached before running this with --yes:"
  log_warn "  apt-cache rdepends --installed texlive-latex-recommended"
  log_warn "  apt-cache rdepends --installed texlive-latex-base"
  log_warn "Your documents survive; the ability to build them does not."
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if [ "${#installed_pkgs[@]}" -gt 0 ]; then
  log_info "Removing: ${installed_pkgs[*]}"
  sudo -E apt-get remove -y "${installed_pkgs[@]}" || true
  sudo -E apt-get autoremove -y || true
  log_ok "LaTeX packages removed."
else
  log_ok "No LaTeX packages from this module installed — skipping."
fi

log_info "Refreshing apt..."
sudo -E apt-get update -y

log_ok "LaTeX uninstall complete."
log_warn "Your .tex sources, .bib files and built PDFs were NOT touched."
log_warn "~/texmf was NOT touched — remove it by hand only if you are certain."
