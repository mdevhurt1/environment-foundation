#!/usr/bin/env bash
# Description: Installs Boatswain (Stream Deck controller) from Flathub and the udev rule that grants the desktop user access to Elgato Stream Deck devices.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: 02-core-packages.sh, flatpak (installed here if absent)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

export DEBIAN_FRONTEND=noninteractive

APP_ID="com.feaneron.Boatswain"
RULE_PATH="/etc/udev/rules.d/10-streamdeck.rules"
# Elgato Systems GmbH vendor ID. Matches every Stream Deck model, so the rule
# does not need updating when the hardware changes.
RULE_CONTENT='SUBSYSTEMS=="usb", ATTRS{idVendor}=="0fd9", GROUP="users", TAG+="uaccess"'

# --- Boatswain (Flathub) ------------------------------------------------------
install_boatswain() {
    if flatpak info "$APP_ID" &>/dev/null; then
        log_ok "Boatswain already installed — skipping."
        return
    fi

    if ! command -v flatpak &>/dev/null; then
        log_info "Installing flatpak..."
        sudo -E apt-get update -y
        sudo -E apt-get install -y flatpak
        log_ok "flatpak installed"
    fi

    log_info "Adding the Flathub remote (if not already present)..."
    sudo flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo

    log_info "Installing Boatswain from Flathub..."
    sudo flatpak install -y flathub "$APP_ID"
    log_ok "Boatswain installed."
}

# --- udev rule ----------------------------------------------------------------
# Without this, the Stream Deck enumerates as a root-owned hidraw node and
# Boatswain shows "no devices found". TAG+="uaccess" hands the logged-in
# session ownership via logind; GROUP="users" is the fallback for setups where
# uaccess does not apply.
RULE_CHANGED=0

install_udev_rule() {
    # udev rules are mode 644, so compare without sudo — this keeps the
    # already-installed path completely free of password prompts. If the file
    # is somehow unreadable, fall through and rewrite it.
    if [ -r "$RULE_PATH" ] && [ "$(cat "$RULE_PATH")" = "$RULE_CONTENT" ]; then
        log_ok "udev rule already present and current — skipping."
        return
    fi

    log_info "Writing $RULE_PATH..."
    printf '%s\n' "$RULE_CONTENT" | sudo tee "$RULE_PATH" >/dev/null
    log_ok "udev rule written."

    log_info "Reloading udev rules..."
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    log_ok "udev rules reloaded and triggered."
    RULE_CHANGED=1
}

main() {
    install_boatswain
    install_udev_rule

    # Only demand a replug when the rule actually changed — an already-correct
    # rule means attached devices already have the right permissions.
    if [ "$RULE_CHANGED" -eq 1 ]; then
        log_warn ">>> REPLUG REQUIRED <<<"
        log_warn "Physically unplug and reconnect the Stream Deck so it re-enumerates"
        log_warn "under the new rule. Already-attached devices keep their old permissions."
    fi

    log_info "Launch Boatswain from the application menu or run:"
    log_info "  flatpak run $APP_ID"
    log_ok "Stream Deck install complete. Verify with: bash scripts/verify.sh"
}

main "$@"
