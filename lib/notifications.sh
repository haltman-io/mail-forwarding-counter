#!/usr/bin/env bash
# =============================================================================
# Mail Counter - Notification Functions
# =============================================================================
# Provides: log, send_webhook, send_telegram, send_email
# Sourced by mail-counter.sh — do not execute directly
# =============================================================================

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [${level^^}] $message" >&2

    local syslog_priority="user.info"
    case "${level,,}" in
        warn|warning) syslog_priority="user.warning" ;;
        error|err)    syslog_priority="user.err" ;;
    esac
    logger -t "${LOG_TAG:-mail-counter}" -p "$syslog_priority" "$message" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Webhook (curl with retry + exponential backoff)
# ---------------------------------------------------------------------------
send_webhook() {
    local url="${1:-$WEBHOOK_URL}"
    local retries=0
    local backoff="${CURL_INITIAL_BACKOFF:-2}"
    local max_retries="${CURL_MAX_RETRIES:-5}"
    local max_backoff="${CURL_MAX_BACKOFF:-60}"
    local http_code

    while (( retries <= max_retries )); do
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 10 --max-time 30 "$url" 2>/dev/null) || http_code="000"

        if [[ "$http_code" == "200" ]]; then
            log info "Webhook OK (HTTP 200) -> $url"
            return 0
        fi

        retries=$((retries + 1))
        if (( retries > max_retries )); then
            break
        fi

        log warn "Webhook returned HTTP $http_code, retry $retries/$max_retries in ${backoff}s"
        sleep "$backoff"
        backoff=$((backoff * 2))
        (( backoff > max_backoff )) && backoff=$max_backoff
    done

    log error "Webhook failed after $max_retries retries (last HTTP $http_code)"
    return 1
}

# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------
send_telegram() {
    local text="$1"

    if [[ "${TELEGRAM_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        log warn "Telegram enabled but BOT_TOKEN or CHAT_ID is empty, skipping"
        return 0
    fi

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    local response
    local http_code

    response=$(curl -s -w '\n%{http_code}' --connect-timeout 10 --max-time 30 \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg chat_id "$TELEGRAM_CHAT_ID" --arg text "$text" \
            '{chat_id: $chat_id, text: $text, parse_mode: "HTML"}')" 2>/dev/null) || {
        log error "Telegram: curl failed"
        return 1
    }

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    local ok
    ok=$(echo "$body" | jq -r '.ok // false' 2>/dev/null) || ok="false"

    if [[ "$ok" == "true" ]]; then
        log info "Telegram notification sent"
        return 0
    else
        local description
        description=$(echo "$body" | jq -r '.description // "unknown error"' 2>/dev/null) || description="unknown"
        log error "Telegram failed (HTTP $http_code): $description"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Email via swaks
# ---------------------------------------------------------------------------
send_email() {
    local subject="$1"
    local body="$2"

    if [[ "${SMTP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    if [[ -z "${SMTP_TO:-}" || -z "${SMTP_FROM:-}" || -z "${SMTP_SERVER:-}" ]]; then
        log warn "SMTP enabled but TO, FROM, or SERVER is empty, skipping"
        return 0
    fi

    local swaks_cmd=(swaks
        --to "$SMTP_TO"
        --from "$SMTP_FROM"
        --server "${SMTP_SERVER}:${SMTP_PORT:-587}"
        --header "Subject: $subject"
        --body "$body"
    )

    if [[ -n "${SMTP_USER:-}" && -n "${SMTP_PASSWORD:-}" ]]; then
        swaks_cmd+=(--auth --auth-user "$SMTP_USER" --auth-password "$SMTP_PASSWORD")
    fi

    if [[ "${SMTP_TLS:-true}" == "true" ]]; then
        swaks_cmd+=(--tls)
    fi

    if "${swaks_cmd[@]}" >/dev/null 2>&1; then
        log info "Email sent to $SMTP_TO"
        return 0
    else
        local exit_code=$?
        log error "Email failed (swaks exit code: $exit_code)"
        return 1
    fi
}
