#!/usr/bin/env bash
#
# humanityz-watchdog.sh
#
# Unified watchdog daemon for HumanitZ Dedicated Server.
# Replaces the old timer-based nightly restart with proactive monitoring:
#
#   - Checks for game updates every 5 minutes (SteamCMD buildid comparison)
#   - Monitors server health via RCON (5 retries per check)
#   - 15-minute player countdown (warnings every minute) before restarts
#   - Verifies RCON after every restart; re-restarts if RCON fails to bind
#   - Daily scheduled restart at 03:30 UTC
#   - Cooldown protection against infinite restart loops
#
# Decision logic per check cycle:
#
#   Update available + RCON up    → 15-min countdown, then restart
#   Update available + RCON down  → immediate restart
#   Daily restart due + RCON up   → 15-min countdown, then restart
#   Daily restart due + RCON down → immediate restart
#   No update + RCON down         → immediate restart
#   No update + RCON up           → all clear, sleep until next check
#
# The server service (humanityz.service) handles backup + SteamCMD update
# in ExecStartPre, so every restart automatically applies pending updates.
#
# Managed by: humanityz-watchdog.service (systemd)
#

set -u

###############################################################################
# CONFIGURATION
###############################################################################

RCON_HOST="127.0.0.1"
RCON_PORT="8888"
RCON_PASS='K@roul1a!'
RCON_BIN="rcon"

SERVICE_NAME="humanityz.service"

APP_ID="2728330"
BETA_BRANCH="linuxbranch"
INSTALL_DIR="/home/ubuntu/humanityz"
MANIFEST_FILE="${INSTALL_DIR}/steamapps/appmanifest_${APP_ID}.acf"

LOG_FILE="/var/log/humanityz-watchdog.log"

# -- Timing --
CHECK_INTERVAL=300              # Seconds between monitoring cycles (5 min)
COUNTDOWN_MINUTES=15            # Warning period before restart (minutes)
DAILY_RESTART_HOUR=3            # UTC hour for daily restart
DAILY_RESTART_MINUTE=30         # UTC minute for daily restart

# -- Retry / safety --
RCON_MAX_RETRIES=5              # RCON attempts per health check
RCON_RETRY_DELAY=5              # Seconds between RCON retries
POST_RESTART_TIMEOUT=180        # Max seconds to wait for RCON after a restart
POST_RESTART_POLL=10            # Seconds between RCON polls post-restart
MAX_CONSECUTIVE_RESTARTS=3      # Restarts before entering cooldown
COOLDOWN_PERIOD=600             # Cooldown duration in seconds (10 min)
STEAMCMD_TIMEOUT=60             # SteamCMD query timeout in seconds

###############################################################################
# STATE (runtime only — not persisted across watchdog restarts)
###############################################################################

DAILY_RESTART_DONE=""           # YYYY-MM-DD of last completed daily restart
CONSECUTIVE_RESTARTS=0          # Back-to-back restart failure counter

###############################################################################
# INIT
###############################################################################

sudo touch "$LOG_FILE"
sudo chown "$(id -un):$(id -gn)" "$LOG_FILE"

###############################################################################
# LOGGING
###############################################################################

log() {
    local level="$1"; shift
    printf '[%s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        | tee -a "$LOG_FILE"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

###############################################################################
# RCON FUNCTIONS
###############################################################################

# Send an RCON command with configurable retries.
# Usage: send_rcon "command" [max_retries]
# Returns 0 on success, 1 if all attempts fail.
send_rcon() {
    local message="$1"
    local max_retries="${2:-$RCON_MAX_RETRIES}"
    local attempt=1

    while [ "$attempt" -le "$max_retries" ]; do
        if "$RCON_BIN" -a "${RCON_HOST}:${RCON_PORT}" -p "$RCON_PASS" \
           "$message" >/dev/null 2>>"$LOG_FILE"; then
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_retries" ] && sleep "$RCON_RETRY_DELAY"
    done
    return 1
}

# Full RCON health check with all configured retries.
# Returns 0 = healthy, 1 = unreachable.
check_rcon() {
    send_rcon "info" "$RCON_MAX_RETRIES"
}

# Quick single-attempt RCON probe (used in polling loops).
check_rcon_quick() {
    "$RCON_BIN" -a "${RCON_HOST}:${RCON_PORT}" -p "$RCON_PASS" "info" \
        >/dev/null 2>/dev/null
}

###############################################################################
# UPDATE DETECTION
###############################################################################

# Read the installed buildid from the local Steam app manifest.
get_local_buildid() {
    if [ ! -f "$MANIFEST_FILE" ]; then
        echo ""; return
    fi
    grep '"buildid"' "$MANIFEST_FILE" 2>/dev/null | head -1 | tr -dc '0-9'
}

# Query Steam for the latest buildid of our beta branch.
get_remote_buildid() {
    local output
    # Double app_info_print: first call populates the SteamCMD info cache,
    # second call returns the actual data (known SteamCMD quirk).
    output=$(timeout "$STEAMCMD_TIMEOUT" /usr/games/steamcmd \
        +login anonymous \
        +app_info_update 1 \
        +app_info_print "$APP_ID" \
        +app_info_print "$APP_ID" \
        +quit 2>&1) || true

    if [ -z "$output" ]; then
        echo ""; return
    fi

    # Parse VDF: isolate the beta branch block, extract its buildid.
    echo "$output" \
        | sed -n "/\"${BETA_BRANCH}\"/,/}/p" \
        | grep '"buildid"' \
        | head -1 \
        | tr -dc '0-9'
}

# Returns 0 if a game update is available, 1 otherwise (or unknown).
check_update_available() {
    local local_id remote_id

    local_id=$(get_local_buildid)
    if [ -z "$local_id" ]; then
        log_warn "Cannot read local buildid from ${MANIFEST_FILE}"
        return 1
    fi

    remote_id=$(get_remote_buildid)
    if [ -z "$remote_id" ]; then
        log_warn "Cannot fetch remote buildid from Steam"
        return 1
    fi

    if [ "$local_id" != "$remote_id" ]; then
        log_info "Update available: installed=${local_id} → latest=${remote_id}"
        return 0
    fi

    return 1
}

###############################################################################
# DAILY RESTART
###############################################################################

# Returns 0 if the daily restart window is active, 1 otherwise.
check_daily_restart_due() {
    local current_date current_hour current_minute
    current_date=$(date -u +%Y-%m-%d)
    current_hour=$(date -u +%-H)
    current_minute=$(date -u +%-M)

    # Already performed today?
    if [ "$DAILY_RESTART_DONE" = "$current_date" ]; then
        return 1
    fi

    # Within the 5-minute restart window? (aligned with CHECK_INTERVAL)
    if [ "$current_hour" -eq "$DAILY_RESTART_HOUR" ] && \
       [ "$current_minute" -ge "$DAILY_RESTART_MINUTE" ] && \
       [ "$current_minute" -lt $((DAILY_RESTART_MINUTE + 5)) ]; then
        return 0
    fi

    return 1
}

###############################################################################
# COUNTDOWN
###############################################################################

# Send countdown warnings via RCON, one message per minute.
# Args: $1 = reason string, $2 = total minutes
# Returns 0 on completion, 1 if RCON failed mid-countdown.
do_countdown() {
    local reason="$1"
    local minutes="$2"

    log_info "Starting ${minutes}-minute countdown: ${reason}"

    local m
    for (( m = minutes; m > 0; m-- )); do
        local msg
        if [ "$m" -eq 1 ]; then
            msg="admin [SERVER] ${reason} — Restarting in 1 minute!"
        else
            msg="admin [SERVER] ${reason} — Restarting in ${m} minutes."
        fi

        if ! send_rcon "$msg" "$RCON_MAX_RETRIES"; then
            log_warn "RCON failed during countdown at T-${m}min. Server may have crashed."
            return 1
        fi

        sleep 60
    done

    # Final "NOW" message just before restart
    send_rcon "admin [SERVER] ${reason} — Restarting NOW!" "$RCON_MAX_RETRIES" || true
    sleep 2
    return 0
}

###############################################################################
# SERVER RESTART & VERIFICATION
###############################################################################

# Restart the server service and poll until RCON comes online.
# Args: $1 = reason string
# Returns 0 = server healthy, 1 = RCON never came up.
restart_server() {
    local reason="$1"
    log_info "Restarting ${SERVICE_NAME}: ${reason}"

    if ! sudo systemctl restart "$SERVICE_NAME"; then
        log_error "systemctl restart failed!"
        CONSECUTIVE_RESTARTS=$((CONSECUTIVE_RESTARTS + 1))
        return 1
    fi

    log_info "Restart accepted. Polling for RCON (timeout ${POST_RESTART_TIMEOUT}s)..."

    local elapsed=0
    while [ "$elapsed" -lt "$POST_RESTART_TIMEOUT" ]; do
        sleep "$POST_RESTART_POLL"
        elapsed=$((elapsed + POST_RESTART_POLL))

        if check_rcon_quick; then
            log_info "RCON online after ~${elapsed}s. Server verified healthy."
            CONSECUTIVE_RESTARTS=0
            return 0
        fi

        # Bail early if the service itself has failed
        local svc
        svc=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")
        if [ "$svc" = "failed" ] || [ "$svc" = "inactive" ]; then
            log_error "Service entered '${svc}' state during boot!"
            CONSECUTIVE_RESTARTS=$((CONSECUTIVE_RESTARTS + 1))
            return 1
        fi
    done

    log_error "RCON did not come online within ${POST_RESTART_TIMEOUT}s!"
    CONSECUTIVE_RESTARTS=$((CONSECUTIVE_RESTARTS + 1))
    return 1
}

###############################################################################
# MAIN
###############################################################################

main() {
    log_info "=============================================="
    log_info "HumanitZ watchdog started"
    log_info "  Check interval:       $(( CHECK_INTERVAL / 60 ))min"
    log_info "  Countdown:            ${COUNTDOWN_MINUTES}min"
    log_info "  Daily restart:        $(printf '%02d:%02d' $DAILY_RESTART_HOUR $DAILY_RESTART_MINUTE) UTC"
    log_info "  RCON retries:         ${RCON_MAX_RETRIES} × ${RCON_RETRY_DELAY}s"
    log_info "  Restart cooldown:     ${MAX_CONSECUTIVE_RESTARTS} failures → ${COOLDOWN_PERIOD}s wait"
    log_info "=============================================="

    # ── Initial boot grace period ──────────────────────────────────────
    # The server may still be loading when the watchdog starts (e.g. after
    # a reboot).  Poll for RCON before entering the monitoring loop so we
    # don't immediately flag a false-positive RCON failure.
    log_info "Waiting for server to finish booting..."
    local boot_elapsed=0
    while [ "$boot_elapsed" -lt "$POST_RESTART_TIMEOUT" ]; do
        sleep "$POST_RESTART_POLL"
        boot_elapsed=$((boot_elapsed + POST_RESTART_POLL))
        if check_rcon_quick; then
            log_info "Server RCON online (${boot_elapsed}s). Entering monitoring loop."
            break
        fi
    done

    if ! check_rcon_quick; then
        log_warn "RCON not online after ${POST_RESTART_TIMEOUT}s boot wait. Proceeding to monitoring loop."
    fi

    # ── Monitoring loop ────────────────────────────────────────────────
    while true; do

        # -- Cooldown guard --
        if [ "$CONSECUTIVE_RESTARTS" -ge "$MAX_CONSECUTIVE_RESTARTS" ]; then
            log_error "Hit ${MAX_CONSECUTIVE_RESTARTS} consecutive restart failures. Cooling down for ${COOLDOWN_PERIOD}s..."
            sleep "$COOLDOWN_PERIOD"
            CONSECUTIVE_RESTARTS=0
            log_info "Cooldown complete. Resuming monitoring."
        fi

        # -- Check service state --
        local svc_state
        svc_state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")

        if [ "$svc_state" = "inactive" ]; then
            log_info "Service is stopped (inactive). Skipping checks."
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if [ "$svc_state" = "activating" ]; then
            log_info "Service is still starting. Waiting 30s..."
            sleep 30
            continue
        fi

        # -- Gather state --
        local update_available=false
        local rcon_ok=false
        local daily_due=false
        local restart_reason=""

        # Daily restart?
        if check_daily_restart_due; then
            daily_due=true
            restart_reason="Daily scheduled restart"
            log_info "Daily restart window reached."
        fi

        # Update available?
        if check_update_available; then
            update_available=true
            if [ -n "$restart_reason" ]; then
                restart_reason="${restart_reason} + game update"
            else
                restart_reason="Game update available"
            fi
        fi

        # RCON healthy?
        if check_rcon; then
            rcon_ok=true
        else
            log_warn "RCON health check failed (${RCON_MAX_RETRIES} retries exhausted)."
            if [ -n "$restart_reason" ]; then
                restart_reason="${restart_reason} + RCON down"
            else
                restart_reason="RCON unresponsive"
            fi
        fi

        # -- Decide --
        if [ "$daily_due" = false ] && \
           [ "$update_available" = false ] && \
           [ "$rcon_ok" = true ]; then
            log_info "All clear. Next check in ${CHECK_INTERVAL}s."
            sleep "$CHECK_INTERVAL"
            continue
        fi

        log_info ">>> Action required: ${restart_reason}"

        # -- Countdown (only if players can be warned) --
        if [ "$rcon_ok" = true ]; then
            if ! do_countdown "$restart_reason" "$COUNTDOWN_MINUTES"; then
                log_warn "Countdown interrupted (RCON lost). Proceeding with restart."
            fi
        else
            log_info "RCON unavailable — restarting immediately (no player warning)."
        fi

        # -- Restart --
        if restart_server "$restart_reason"; then
            log_info "Restart successful. Server verified."
        else
            log_error "Restart or RCON verification failed. Will retry next cycle."
            sleep 30
            continue
        fi

        # -- Mark daily restart as done --
        # If any restart happens during the daily restart hour, credit it as
        # the daily restart to prevent a redundant second restart.
        local cur_date cur_hour
        cur_date=$(date -u +%Y-%m-%d)
        cur_hour=$(date -u +%-H)
        if [ "$daily_due" = true ] || [ "$cur_hour" -eq "$DAILY_RESTART_HOUR" ]; then
            DAILY_RESTART_DONE="$cur_date"
            log_info "Daily restart marked done for ${DAILY_RESTART_DONE}."
        fi

        log_info "Monitoring resumed. Next check in ${CHECK_INTERVAL}s."
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
