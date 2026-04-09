#!/usr/bin/env bash
# =============================================================================
# Mail Counter - Installer
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/mail-counter"
CONFIG_FILE="/etc/mail-counter.conf"
STATE_DIR="/var/lib/mail-counter"
SERVICE_FILE="/etc/systemd/system/mail-counter.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
info "Checking dependencies..."

MISSING=()
for cmd in journalctl jq curl bash; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING+=("$cmd")
    fi
done

if ! command -v swaks &>/dev/null; then
    warn "swaks not found. Email notifications will not work."
    warn "Install with: apt install swaks"
fi

if (( ${#MISSING[@]} > 0 )); then
    error "Missing required dependencies: ${MISSING[*]}"
    error "Install with: apt install ${MISSING[*]}"
    exit 1
fi

# Check bash version
BASH_MAJOR="${BASH_VERSINFO[0]}"
if (( BASH_MAJOR < 4 )); then
    error "Bash 4.0+ required (found ${BASH_VERSION})"
    exit 1
fi

info "All required dependencies found"

# ---------------------------------------------------------------------------
# Install files
# ---------------------------------------------------------------------------
info "Installing to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}/lib"

cp "${SCRIPT_DIR}/mail-counter.sh"       "${INSTALL_DIR}/mail-counter.sh"
cp "${SCRIPT_DIR}/lib/notifications.sh"  "${INSTALL_DIR}/lib/notifications.sh"
cp "${SCRIPT_DIR}/lib/queue.sh"          "${INSTALL_DIR}/lib/queue.sh"

chmod +x "${INSTALL_DIR}/mail-counter.sh"
chmod 644 "${INSTALL_DIR}/lib/notifications.sh"
chmod 644 "${INSTALL_DIR}/lib/queue.sh"

# Copy documentation if present
for doc in INSTALL.md; do
    if [[ -f "${SCRIPT_DIR}/${doc}" ]]; then
        cp "${SCRIPT_DIR}/${doc}" "${INSTALL_DIR}/${doc}"
    fi
done

info "Scripts installed"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if [[ -f "${CONFIG_FILE}" ]]; then
    warn "Config ${CONFIG_FILE} already exists, not overwriting"
    warn "Review ${SCRIPT_DIR}/mail-counter.conf for new options"
else
    cp "${SCRIPT_DIR}/mail-counter.conf" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    info "Config installed to ${CONFIG_FILE} (mode 600)"
fi

# ---------------------------------------------------------------------------
# State directory
# ---------------------------------------------------------------------------
mkdir -p "${STATE_DIR}/queue"
chmod 750 "${STATE_DIR}"
info "State directory created at ${STATE_DIR}"

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------
cp "${SCRIPT_DIR}/mail-counter.service" "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable mail-counter.service
info "systemd service installed and enabled"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
info "Validating installation..."

if bash -n "${INSTALL_DIR}/mail-counter.sh" 2>&1; then
    info "Script syntax OK"
else
    error "Script syntax check failed!"
    exit 1
fi

if bash -n "${INSTALL_DIR}/lib/notifications.sh" 2>&1; then
    info "Notifications library syntax OK"
else
    error "Notifications library syntax check failed!"
fi

if bash -n "${INSTALL_DIR}/lib/queue.sh" 2>&1; then
    info "Queue library syntax OK"
else
    error "Queue library syntax check failed!"
fi

if systemd-analyze verify "${SERVICE_FILE}" 2>&1 | grep -v "Unknown lvalue"; then
    info "systemd unit validation passed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Mail Counter installed successfully!"
echo "=========================================="
echo ""
echo "  Scripts:  ${INSTALL_DIR}/"
echo "  Config:   ${CONFIG_FILE}"
echo "  State:    ${STATE_DIR}/"
echo "  Service:  mail-counter.service"
echo ""
echo "  Next steps:"
echo "    1. Edit config:    nano ${CONFIG_FILE}"
echo "    2. Start service:  systemctl start mail-counter"
echo "    3. Check status:   systemctl status mail-counter"
echo "    4. View logs:      journalctl -u mail-counter -f"
echo ""
