#!/usr/bin/env bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$BASE_DIR/nids.conf"
LOG_DIR="$BASE_DIR/log"
LOG_FILE="$LOG_DIR/nids.log"
CONTROL_SCRIPT="$BASE_DIR/control.sh"
FAILSAFE_SCRIPT="$BASE_DIR/failsafe.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Nedostaje konfiguracija: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

mkdir -p "$LOG_DIR"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] NIDS se mora pokrenuti kao root."
    exit 1
fi

if ! command -v tcpdump >/dev/null 2>&1; then
    echo "[ERROR] tcpdump nije instaliran."
    exit 1
fi

if ! command -v ncat >/dev/null 2>&1; then
    echo "[ERROR] ncat nije instaliran."
    exit 1
fi

if [[ ! -x "$CONTROL_SCRIPT" ]]; then
    echo "[ERROR] Control skripta nije dostupna ili nije izvršna: $CONTROL_SCRIPT"
    exit 1
fi

if [[ ! -f "$FAILSAFE_SCRIPT" ]]; then
    echo "[ERROR] Nedostaje fail-safe modul: $FAILSAFE_SCRIPT"
    exit 1
fi

# --------------------------------------------------
# Logging
# --------------------------------------------------

log() {
    local level="$1"
    shift

    echo "[$(date -u '+%Y-%m-%d %H:%M:%S.%3N')] [$level] $*" |
        tee -a "$LOG_FILE"
}

# --------------------------------------------------
# TLS konfiguracija
# --------------------------------------------------

TLS_ENABLE="${TLS_ENABLE:-0}"

resolve_path() {
    local path="$1"

    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$BASE_DIR" "${path#./}"
    fi
}

if [[ "$TLS_ENABLE" == "1" ]]; then
    TLS_CA="$(resolve_path "${TLS_CA:-./ssl/ca-cert.pem}")"

    if [[ ! -f "$TLS_CA" ]]; then
        echo "[ERROR] TLS CA certifikat ne postoji: $TLS_CA"
        exit 1
    fi
fi

source "$FAILSAFE_SCRIPT"

# --------------------------------------------------
# Slanje NIDS_ALERT poruke centralnom serveru
# --------------------------------------------------

send_alert_to_server() {
    local message="$1"
    local target="$SERVER_IP"
    local cmd

    if [[ "$TLS_ENABLE" == "1" ]]; then
        target="server"

        if ! getent hosts "$target" >/dev/null 2>&1; then
            log "WARNING" "TLS hostname '$target' nije moguće razriješiti"
            return 1
        fi

        cmd=(
            ncat
            --send-only
            --wait 2s
            --ssl
            --ssl-verify
            --ssl-trustfile "$TLS_CA"
            "$target"
            "$SERVER_PORT"
        )
    else
        cmd=(
            ncat
            --send-only
            --wait 2s
            "$SERVER_IP"
            "$SERVER_PORT"
        )
    fi

    if printf '%s\n' "$message" | "${cmd[@]}" 2>/dev/null; then
        log "INFO" \
            "NIDS_ALERT poslan serveru $target:$SERVER_PORT tls=$TLS_ENABLE"
        return 0
    fi

    log "WARNING" \
        "Neuspjelo slanje NIDS_ALERT serveru $target:$SERVER_PORT tls=$TLS_ENABLE"
    return 1
}

# --------------------------------------------------
# Runtime state
# --------------------------------------------------

CONTROL_PID=""

# --------------------------------------------------
# Cleanup
# --------------------------------------------------

cleanup() {
    local exit_code="${1:-0}"

    log "INFO" "Zaustavljam NIDS"

    if [[ -n "$CONTROL_PID" ]] &&
       kill -0 "$CONTROL_PID" 2>/dev/null; then

        log "INFO" \
            "Zaustavljam NIDS control listener PID=$CONTROL_PID"

        kill "$CONTROL_PID" 2>/dev/null
        wait "$CONTROL_PID" 2>/dev/null || true
    fi

    exit "$exit_code"
}

trap 'cleanup 0' SIGINT SIGTERM

# --------------------------------------------------
# ICMP stanje
# --------------------------------------------------

declare -A ICMP_COUNT
declare -A ICMP_WINDOW_START
declare -A LAST_ALERT

# --------------------------------------------------
# Startup
# --------------------------------------------------

log "INFO" "Pokrecem NIDS (TLS=$TLS_ENABLE)"
log "INFO" "Interface=$INTERFACE ProtectedNet=$PROTECTED_NET"
log "INFO" \
    "ICMP_WINDOW=${ICMP_WINDOW}s ICMP_THRESHOLD=$ICMP_THRESHOLD ALERT_COOLDOWN=${ALERT_COOLDOWN}s"
log "INFO" \
    "EmergencyBlock=$EMERGENCY_BLOCK_ENABLE EmergencyTTL=${EMERGENCY_BLOCK_TTL}s ServerCheckRetries=$SERVER_CHECK_RETRIES"

"$CONTROL_SCRIPT" &
CONTROL_PID=$!

CONTROL_READY=0

for _ in {1..20}; do
    if ! kill -0 "$CONTROL_PID" 2>/dev/null; then
        log "ERROR" "NIDS control listener se ugasio tijekom startupa"
        wait "$CONTROL_PID" 2>/dev/null || true
        exit 1
    fi

    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "(:|\])${CONTROL_PORT}$"; then
        CONTROL_READY=1
        break
    fi

    sleep 0.25
done

if (( CONTROL_READY == 0 )); then
    log "ERROR" \
        "NIDS control listener nije spreman na portu $CONTROL_PORT nakon startup timeouta"
    kill "$CONTROL_PID" 2>/dev/null || true
    wait "$CONTROL_PID" 2>/dev/null || true
    exit 1
fi

log "INFO" \
    "NIDS control listener spreman PID=$CONTROL_PID port=$CONTROL_PORT"

# --------------------------------------------------
# NIDS detekcija
# --------------------------------------------------

while IFS= read -r packet; do
    # Per-packet logging iskljucen radi pouzdanijih flood eksperimenata.

    if [[ "$packet" != *"ICMP echo request"* ]]; then
        continue
    fi

    src="$(awk '{print $3}' <<< "$packet")"
    dst="$(awk '{print $5}' <<< "$packet" | tr -d ':')"

    if [[ -z "$src" || -z "$dst" ]]; then
        continue
    fi

    key="${src}_${dst}"
    now="$(date +%s)"

    if [[ -z "${ICMP_WINDOW_START[$key]+x}" ]] ||
       (( now - ICMP_WINDOW_START[$key] >= ICMP_WINDOW )); then

        ICMP_WINDOW_START[$key]=$now
        ICMP_COUNT[$key]=1
    else
        (( ICMP_COUNT[$key]++ ))
    fi

    if (( ICMP_COUNT[$key] >= ICMP_THRESHOLD )); then
        last_alert="${LAST_ALERT[$key]:-0}"

        if (( now - last_alert >= ALERT_COOLDOWN )); then
            alert_message="NIDS_ALERT nids type=ICMP_FLOOD src=$src dst=$dst count=${ICMP_COUNT[$key]} window=${ICMP_WINDOW}s threshold=$ICMP_THRESHOLD"

            log "NIDS_ALERT" \
                "type=ICMP_FLOOD src=$src dst=$dst count=${ICMP_COUNT[$key]} window=${ICMP_WINDOW}s threshold=$ICMP_THRESHOLD"

            if ! send_alert_to_server "$alert_message"; then
                handle_server_failsafe "$src" "$dst"
            fi

            LAST_ALERT[$key]=$now
        fi
    fi

done < <(
    tcpdump \
        -l \
        -nn \
        -i "$INTERFACE" \
        "ip and dst net $PROTECTED_NET" \
        2>/dev/null
)

log "ERROR" \
    "tcpdump capture stream je neocekivano zavrsio; NIDS detekcija vise nije aktivna"

cleanup 1
