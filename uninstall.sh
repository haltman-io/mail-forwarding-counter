#!/usr/bin/env bash
# =============================================================================
# Mail Counter - Uninstaller
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/mail-counter"
CONFIG_FILE="/etc/mail-counter.conf"
STATE_DIR="/var/lib/mail-counter"
SERVICE_FILE="/etc/systemd/system/mail-counter.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root"
    exit 1
fi

# ---------------------------------------------------------------------------
# Stop and disable service
# ---------------------------------------------------------------------------
if systemctl is-active --quiet mail-counter 2>/dev/null; then
    info "Stopping mail-counter service..."
    systemctl stop mail-counter
fi

if systemctl is-enabled --quiet mail-counter 2>/dev/null; then
    info "Disabling mail-counter service..."
    systemctl disable mail-counter
fi

if [[ -f "${SERVICE_FILE}" ]]; then
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    info "systemd unit removed"
fi

# ---------------------------------------------------------------------------
# Remove install directory
# ---------------------------------------------------------------------------
if [[ -d "${INSTALL_DIR}" ]]; then
    rm -rf "${INSTALL_DIR}"
    info "Removed ${INSTALL_DIR}"
fi

# ---------------------------------------------------------------------------
# Prompt for state data
# ---------------------------------------------------------------------------
if [[ -d "${STATE_DIR}" ]]; then
    echo ""
    read -rp "Remove state data (${STATE_DIR})? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        rm -rf "${STATE_DIR}"
        info "Removed ${STATE_DIR}"
    else
        warn "State data preserved at ${STATE_DIR}"
    fi
fi

# ---------------------------------------------------------------------------
# Prompt for config
# ---------------------------------------------------------------------------
if [[ -f "${CONFIG_FILE}" ]]; then
    echo ""
    read -rp "Remove config (${CONFIG_FILE})? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        rm -f "${CONFIG_FILE}"
        info "Removed ${CONFIG_FILE}"
    else
        warn "Config preserved at ${CONFIG_FILE}"
    fi
fi

echo ""
info "Mail Counter uninstalled."
