#!/usr/bin/env bash
# =============================================================================
# Mail Counter - Postfix status=sent Monitor
# =============================================================================
# Monitors Postfix logs via journald, detects status=sent events,
# triggers webhook + Telegram + email notifications.
# Designed to run as a systemd service with automatic restart.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
source_libs() {
    source "${SCRIPT_DIR}/lib/notifications.sh"
    source "${SCRIPT_DIR}/lib/queue.sh"
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
load_config() {
    if [[ -f /etc/mail-counter.conf ]]; then
        source /etc/mail-counter.conf
    elif [[ -f "${SCRIPT_DIR}/mail-counter.conf" ]]; then
        source "${SCRIPT_DIR}/mail-counter.conf"
    else
        echo "ERROR: No configuration file found" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Validate required configuration
# ---------------------------------------------------------------------------
validate_config() {
    if [[ -z "${WEBHOOK_URL:-}" ]]; then
        log error "WEBHOOK_URL is not set"
        exit 1
    fi

    if [[ "${TELEGRAM_ENABLED:-false}" == "true" ]]; then
        if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
            log error "TELEGRAM_ENABLED=true but TELEGRAM_BOT_TOKEN is empty"
            exit 1
        fi
        if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
            log error "TELEGRAM_ENABLED=true but TELEGRAM_CHAT_ID is empty"
            exit 1
        fi
    fi

    if [[ "${SMTP_ENABLED:-false}" == "true" ]]; then
        if [[ -z "${SMTP_TO:-}" || -z "${SMTP_FROM:-}" || -z "${SMTP_SERVER:-}" ]]; then
            log error "SMTP_ENABLED=true but SMTP_TO, SMTP_FROM, or SMTP_SERVER is empty"
            exit 1
        fi
        if ! command -v swaks &>/dev/null; then
            log error "SMTP_ENABLED=true but swaks is not installed"
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Ensure state directories exist
# ---------------------------------------------------------------------------
ensure_state_dirs() {
    mkdir -p "${STATE_DIR}" "${QUEUE_DIR}"
    chmod 750 "${STATE_DIR}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# First-run detection
# ---------------------------------------------------------------------------
is_first_run() {
    [[ ! -f "${FIRST_RUN_FILE}" ]]
}

mark_first_run_done() {
    touch "${FIRST_RUN_FILE}"
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local msg="Mail Counter started for the first time on ${hostname} at $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log info "$msg"

    send_telegram "$msg" || enqueue "telegram" "$msg"
    send_email "Mail Counter - First Run" "$msg" || enqueue "email" "$msg" "Mail Counter - First Run"
}

# ---------------------------------------------------------------------------
# Cursor management (atomic writes)
# ---------------------------------------------------------------------------
load_cursor() {
    if [[ -f "${CURSOR_FILE}" ]] && [[ -s "${CURSOR_FILE}" ]]; then
        cat "${CURSOR_FILE}"
    fi
}

save_cursor() {
    local cursor="$1"
    echo "$cursor" > "${CURSOR_FILE}.tmp" && mv "${CURSOR_FILE}.tmp" "${CURSOR_FILE}"
}

# ---------------------------------------------------------------------------
# Extract info from Postfix log message
# ---------------------------------------------------------------------------
extract_mail_info() {
    local message="$1"
    local relay="" dsn="" status_detail=""

    if [[ "$message" =~ relay=([^,]+) ]]; then
        relay="${BASH_REMATCH[1]}"
    fi
    if [[ "$message" =~ dsn=([^,]+) ]]; then
        dsn="${BASH_REMATCH[1]}"
    fi
    if [[ "$message" =~ status=sent\ \((.+)\)$ ]]; then
        status_detail="${BASH_REMATCH[1]}"
    fi

    echo "relay=${relay}|dsn=${dsn}|detail=${status_detail}"
}

# ---------------------------------------------------------------------------
# Process a status=sent event
# ---------------------------------------------------------------------------
process_sent_event() {
    local message="$1"
    local info
    info=$(extract_mail_info "$message")

    local relay dsn detail
    relay=$(echo "$info" | cut -d'|' -f1 | cut -d= -f2)
    dsn=$(echo "$info" | cut -d'|' -f2 | cut -d= -f2)
    detail=$(echo "$info" | cut -d'|' -f3 | cut -d= -f2-)

    local summary="Mail forwarded"
    [[ -n "$relay" ]] && summary="${summary} via ${relay}"
    [[ -n "$dsn" ]] && summary="${summary} (dsn=${dsn})"

    log info "Detected: ${summary}"

    # 1. Webhook
    send_webhook "${WEBHOOK_URL}" || enqueue "webhook" "$summary"

    # 2. Telegram
    if [[ "${TELEGRAM_ENABLED:-false}" == "true" ]]; then
        local telegram_text
        telegram_text="<b>Mail Forwarded</b>
Relay: <code>${relay:-unknown}</code>
DSN: <code>${dsn:-unknown}</code>
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        send_telegram "$telegram_text" || enqueue "telegram" "$telegram_text"
    fi

    # 3. Email
    if [[ "${SMTP_ENABLED:-false}" == "true" ]]; then
        send_email "Mail Forwarded" "$summary" || \
            enqueue "email" "$summary" "Mail Forwarded"
    fi
}

# ---------------------------------------------------------------------------
# Queue processor (runs in background)
# ---------------------------------------------------------------------------
run_queue_processor() {
    while true; do
        sleep "${QUEUE_RETRY_INTERVAL:-300}"
        process_queue || true
    done
}

# ---------------------------------------------------------------------------
# Build journalctl command
# ---------------------------------------------------------------------------
build_journalctl_args() {
    local cursor="$1"
    local args=(-u "${POSTFIX_UNIT:-postfix*}" --output=json --follow --no-pager)

    if [[ -n "$cursor" ]]; then
        args+=(--after-cursor="$cursor")
    else
        args+=(--since=now)
    fi

    printf '%s\n' "${args[@]}"
}

# ---------------------------------------------------------------------------
# Main journal tail loop
# ---------------------------------------------------------------------------
start_journal_tail() {
    local cursor
    cursor=$(load_cursor)

    if [[ -n "$cursor" ]]; then
        log info "Resuming from saved cursor"
    else
        log info "No cursor found, monitoring new events only"
    fi

    local args=()
    while IFS= read -r arg; do
        args+=("$arg")
    done < <(build_journalctl_args "$cursor")

    log info "Starting journal tail: journalctl ${args[*]}"

    local last_cursor="$cursor"

    journalctl "${args[@]}" | while IFS= read -r line; do
        local entry_cursor="" entry_message=""

        entry_cursor=$(echo "$line" | jq -r '.__CURSOR // empty' 2>/dev/null) || continue
        entry_message=$(echo "$line" | jq -r '.MESSAGE // empty' 2>/dev/null) || continue

        # Skip if same cursor as last saved (dedup on resume)
        if [[ -n "$entry_cursor" && "$entry_cursor" == "$last_cursor" ]]; then
            continue
        fi

        # Check for status=sent
        if [[ "$entry_message" == *"status=sent"* ]]; then
            process_sent_event "$entry_message" || true
        fi

        # Save cursor after every line
        if [[ -n "$entry_cursor" ]]; then
            save_cursor "$entry_cursor"
            last_cursor="$entry_cursor"
        fi
    done
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
QUEUE_PID=""

cleanup() {
    log info "Shutting down..."
    if [[ -n "$QUEUE_PID" ]]; then
        kill "$QUEUE_PID" 2>/dev/null || true
        wait "$QUEUE_PID" 2>/dev/null || true
    fi
    log info "Shutdown complete"
}

trap cleanup EXIT SIGTERM SIGINT
trap '' PIPE

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    source_libs
    load_config
    validate_config
    ensure_state_dirs

    log info "Mail Counter starting (PID $$)"

    if is_first_run; then
        log info "First run detected"
        mark_first_run_done
    fi

    # Start queue processor in background
    run_queue_processor &
    QUEUE_PID=$!
    log info "Queue processor started (PID $QUEUE_PID)"

    # Start monitoring
    start_journal_tail

    # If we get here, journalctl exited unexpectedly
    log error "Journal tail exited unexpectedly, exiting for systemd restart"
    exit 1
}

main "$@"
