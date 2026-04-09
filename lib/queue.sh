#!/usr/bin/env bash
# =============================================================================
# Mail Counter - Notification Queue
# =============================================================================
# File-based retry queue for failed notifications.
# Each queued item is a file in QUEUE_DIR with key=value pairs.
# Sourced by mail-counter.sh — do not execute directly.
# =============================================================================

# ---------------------------------------------------------------------------
# Enqueue a failed notification for later retry
# Usage: enqueue <type> <message> [subject]
#   type: webhook | telegram | email
# ---------------------------------------------------------------------------
enqueue() {
    local type="$1"
    local message="$2"
    local subject="${3:-}"
    local timestamp
    timestamp=$(date +%s)
    local random_id
    random_id=$(head -c 6 /dev/urandom | od -A n -t x1 | tr -d ' \n')
    local filename="${timestamp}-${type}-${random_id}.queue"
    local filepath="${QUEUE_DIR}/${filename}"
    local tmpfile="${filepath}.tmp"

    {
        echo "TYPE=${type}"
        echo "TIMESTAMP=${timestamp}"
        echo "MESSAGE=${message}"
        echo "RETRIES=0"
        echo "SUBJECT=${subject}"
    } > "$tmpfile" && mv "$tmpfile" "$filepath"

    log warn "Queued ${type} notification for retry -> ${filename}"
}

# ---------------------------------------------------------------------------
# Update retry count in a queue file
# Usage: update_queue_retries <filepath> <new_count>
# ---------------------------------------------------------------------------
update_queue_retries() {
    local filepath="$1"
    local new_count="$2"
    local tmpfile="${filepath}.tmp"

    local line
    while IFS= read -r line; do
        if [[ "$line" == RETRIES=* ]]; then
            echo "RETRIES=${new_count}"
        else
            echo "$line"
        fi
    done < "$filepath" > "$tmpfile" && mv "$tmpfile" "$filepath"
}

# ---------------------------------------------------------------------------
# Process the queue: oldest first, one at a time
# On success: delete item, small delay, continue
# On failure: increment retries, STOP (no flood)
# ---------------------------------------------------------------------------
process_queue() {
    local queue_files=()
    local f

    for f in "${QUEUE_DIR}"/*.queue; do
        [[ -f "$f" ]] || continue
        queue_files+=("$f")
    done

    if (( ${#queue_files[@]} == 0 )); then
        return 0
    fi

    # Sort by filename (timestamp prefix ensures oldest first)
    IFS=$'\n' queue_files=($(printf '%s\n' "${queue_files[@]}" | sort))
    unset IFS

    log info "Processing queue: ${#queue_files[@]} item(s) pending"

    local qfile
    for qfile in "${queue_files[@]}"; do
        [[ -f "$qfile" ]] || continue

        local TYPE="" MESSAGE="" RETRIES=0 SUBJECT="" TIMESTAMP=""
        local key value
        while IFS='=' read -r key value; do
            case "$key" in
                TYPE)      TYPE="$value" ;;
                MESSAGE)   MESSAGE="$value" ;;
                RETRIES)   RETRIES="$value" ;;
                SUBJECT)   SUBJECT="$value" ;;
                TIMESTAMP) TIMESTAMP="$value" ;;
            esac
        done < "$qfile"

        # Discard if max retries exceeded
        if (( RETRIES >= ${QUEUE_MAX_RETRIES:-48} )); then
            log error "Discarding queued ${TYPE} after ${RETRIES} retries: ${MESSAGE:0:100}"
            rm -f "$qfile"
            continue
        fi

        local success=false
        case "$TYPE" in
            webhook)
                send_webhook "${WEBHOOK_URL}" && success=true
                ;;
            telegram)
                send_telegram "$MESSAGE" && success=true
                ;;
            email)
                send_email "${SUBJECT:-Mail Counter Alert}" "$MESSAGE" && success=true
                ;;
            *)
                log error "Unknown queue item type: ${TYPE}, discarding"
                rm -f "$qfile"
                continue
                ;;
        esac

        if $success; then
            log info "Queue retry succeeded for ${TYPE} (was attempt $((RETRIES + 1)))"
            rm -f "$qfile"
            sleep "${QUEUE_RETRY_DELAY:-5}"
        else
            log warn "Queue retry failed for ${TYPE} (attempt $((RETRIES + 1))), stopping queue"
            update_queue_retries "$qfile" "$((RETRIES + 1))"
            return 0
        fi
    done

    log info "Queue processing complete, all items resolved"
}
