#!/usr/bin/env bash
#
# humanityz-nightly.sh
#
# Nightly restart script for HumanitZ Dedicated Server.
# Sends RCON countdown warnings over 30 minutes, then restarts the service.
# The service itself handles the SteamCMD update via ExecStartPre.
#
# Usage: Run via systemd timer (humanityz-nightly.timer).
#

set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

RCON_HOST="127.0.0.1"
RCON_PORT="8888"
RCON_PASS='K@roul1a!'

SERVICE_NAME="humanityz.service"

# Path to rcon-cli binary (https://github.com/gorcon/rcon-cli)
RCON_BIN="rcon"

# Log file (must be writable by the ubuntu user; /var/log/ requires root)
LOG_FILE="/home/ubuntu/humanityz-nightly.log"

# Maximum RCON retry attempts per message
RCON_MAX_RETRIES=3

# Seconds to wait between RCON retries
RCON_RETRY_DELAY=5

###############################################################################
# INTERNAL
###############################################################################

mkdir -p "$(dirname "$LOG_FILE")"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# -------------------------------------------------------------------
# RCON messaging with retry logic
# -------------------------------------------------------------------
send_rcon() {
    local message="$1"
    local attempt=1

    while [ "$attempt" -le "$RCON_MAX_RETRIES" ]; do
        if "$RCON_BIN" -a "${RCON_HOST}:${RCON_PORT}" -p "$RCON_PASS" "$message" 2>>"$LOG_FILE"; then
            log_info "RCON message sent: $message"
            return 0
        else
            log_warn "RCON attempt $attempt/$RCON_MAX_RETRIES failed for: $message"
            attempt=$((attempt + 1))
            [ "$attempt" -le "$RCON_MAX_RETRIES" ] && sleep "$RCON_RETRY_DELAY"
        fi
    done

    log_error "RCON failed after $RCON_MAX_RETRIES attempts: $message"
    return 1
}

# -------------------------------------------------------------------
# Countdown (30 minutes, warnings every 5 minutes)
# -------------------------------------------------------------------
run_countdown() {
    local minutes_remaining=(30 25 20 15 10 5)

    for i in "${!minutes_remaining[@]}"; do
        local mins="${minutes_remaining[$i]}"

        if ! send_rcon "admin Server restart in ${mins} minutes."; then
            log_error "Failed to send RCON warning at T-${mins}. Aborting."
            exit 1
        fi

        # Sleep 5 minutes between warnings
        if [ "$i" -lt $(( ${#minutes_remaining[@]} - 1 )) ]; then
            log_info "Sleeping 5 minutes until next warning ..."
            sleep 300
        fi
    done

    # Final 5 minutes after the T-5 warning
    log_info "Sleeping final 5 minutes before restart ..."
    sleep 300
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
    log_info "=============================================="
    log_info "HumanitZ nightly restart started."
    log_info "=============================================="

    # Step 1: Countdown warnings
    log_info "Beginning 30-minute restart countdown ..."
    run_countdown

    # Step 2: Restart the service (systemctl handles stop → update → start)
    log_info "Countdown complete. Restarting $SERVICE_NAME ..."
    if sudo systemctl restart "$SERVICE_NAME"; then
        log_info "$SERVICE_NAME restarted successfully."
    else
        log_error "Failed to restart $SERVICE_NAME. Manual intervention required."
        exit 1
    fi

    log_info "=============================================="
    log_info "HumanitZ nightly restart completed."
    log_info "=============================================="
    exit 0
}

main "$@"
