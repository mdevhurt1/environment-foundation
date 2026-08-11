#!/usr/bin/env bash
# Description: Installs a LaTeX toolchain from the Ubuntu archive — the
#              recommended/extra LaTeX package sets, the recommended fonts,
#              Latin Modern, and latexmk. Deliberately not texlive-full.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: apt (texlive-* and latexmk all come from the Ubuntu archive —
#              no third-party repository or keyring is needed)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root
export DEBIAN_FRONTEND=noninteractive

# The install set. See README.md for why this rather than texlive-full.
#
# lmodern is listed explicitly and that is not redundant. It is only a
# *Recommends* of texlive-base, so on a machine with recommends enabled (apt's
# default) it arrives for free — but under --no-install-recommends the four
# headline packages pull in fonts-lmodern (the font files) without lmodern
# (which is what ships lmodern.sty). \usepackage{lmodern} then fails with a
# missing-file error that points at a font package which *is* installed.
# Naming it here makes the set self-sufficient under either apt policy.
PACKAGES=(
  texlive-latex-recommended
  texlive-fonts-recommended
  texlive-latex-extra
  latexmk
  lmodern
)

log_info "Checking for an existing LaTeX toolchain..."

missing=()
for pkg in "${PACKAGES[@]}"; do
  dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
done

if [ "${#missing[@]}" -eq 0 ]; then
  log_ok "All LaTeX packages already installed, skipping apt."
  log_ok "pdflatex: $(pdflatex --version 2>/dev/null | head -1)"
  log_ok "latexmk:  $(latexmk --version 2>/dev/null | head -1)"
  exit 0
fi

log_info "Missing: ${missing[*]}"
log_warn "This is a large download — roughly 400 packages and >1 GB unpacked"
log_warn "with apt recommends enabled. It is still far smaller than texlive-full."

log_info "Installing the LaTeX toolchain..."
sudo -E apt-get update -y
# Install the whole set, not just the missing members: apt-get install is
# idempotent for already-satisfied packages, and naming them all keeps a
# partially-removed toolchain from being left half-repaired.
sudo -E apt-get install -y "${PACKAGES[@]}"

log_ok "LaTeX toolchain installed."
log_ok "pdflatex: $(pdflatex --version 2>/dev/null | head -1)"
log_ok "latexmk:  $(latexmk --version 2>/dev/null | head -1)"
log_info "Verify with: bash $SCRIPT_DIR/verify.sh"
