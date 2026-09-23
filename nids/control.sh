#!/usr/bin/env bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$BASE_DIR/nids.conf"
FIREWALL_SCRIPT="$BASE_DIR/firewall.sh"
LOG_DIR="$BASE_DIR/log"
LOG_FILE="$LOG_DIR/nids.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Nedostaje konfiguracija: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f "$FIREWALL_SCRIPT" ]]; then
    echo "[ERROR] Nedostaje firewall modul: $FIREWALL_SCRIPT"
    exit 1
fi

source "$CONFIG_FILE"
source "$FIREWALL_SCRIPT"

mkdir -p "$LOG_DIR"

if ! command -v ncat >/dev/null 2>&1; then
    echo "[ERROR] ncat nije instaliran."
    exit 1
fi

if ! command -v iptables >/dev/null 2>&1; then
    echo "[ERROR] iptables nije dostupan."
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
# Osnovna konfiguracija
# --------------------------------------------------

if [[ -z "${CONTROL_IP:-}" || -z "${CONTROL_PORT:-}" ]]; then
    log "ERROR" "CONTROL_IP ili CONTROL_PORT nisu definirani u nids.conf"
    exit 1
fi

if [[ -z "${SERVER_IP:-}" || -z "${SERVER_PORT:-}" ]]; then
    log "ERROR" "SERVER_IP ili SERVER_PORT nisu definirani u nids.conf"
    exit 1
fi

TLS_ENABLE="${TLS_ENABLE:-0}"


# --------------------------------------------------
# TLS putanje
#
# nids.conf može sadržavati relativne putanje poput:
# ./ssl/ca-cert.pem
#
# Ovdje ih pretvaramo u apsolutne putanje kako control.sh
# ne bi ovisio o trenutnom working directoryju.
# --------------------------------------------------

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
    TLS_CERT="$(resolve_path "${TLS_CERT:-./ssl/nids-cert.pem}")"
    TLS_KEY="$(resolve_path "${TLS_KEY:-./ssl/nids-key.pem}")"

    if [[ ! -f "$TLS_CA" ]]; then
        log "ERROR" "TLS CA certifikat ne postoji: $TLS_CA"
        exit 1
    fi

    if [[ ! -f "$TLS_CERT" ]]; then
        log "ERROR" "NIDS TLS certifikat ne postoji: $TLS_CERT"
        exit 1
    fi

    if [[ ! -f "$TLS_KEY" ]]; then
        log "ERROR" "NIDS TLS privatni ključ ne postoji: $TLS_KEY"
        exit 1
    fi
fi


# --------------------------------------------------
# Runtime state
# --------------------------------------------------

NCAT_PID=""
MESSAGE_FILE=""


# --------------------------------------------------
# Cleanup
# --------------------------------------------------

cleanup() {
    if [[ -n "$NCAT_PID" ]] &&
       kill -0 "$NCAT_PID" 2>/dev/null; then

        kill "$NCAT_PID" 2>/dev/null
        wait "$NCAT_PID" 2>/dev/null || true
    fi

    if [[ -n "$MESSAGE_FILE" && -f "$MESSAGE_FILE" ]]; then
        rm -f "$MESSAGE_FILE"
    fi

    exit 0
}


# --------------------------------------------------
# Slanje BLOCK_RESULT serveru
# --------------------------------------------------

send_block_result_to_server() {
    local block_result="$1"
    local rc
    local target="$SERVER_IP"
    local cmd

    if [[ "$TLS_ENABLE" == "1" ]]; then

        # Serverov certifikat verificiramo prema DNS imenu "server".
        target="server"

        if ! getent hosts "$target" >/dev/null 2>&1; then
            log "CONTROL_RESULT_SEND" \
                "status=FAIL reason=SERVER_HOSTNAME_UNRESOLVED hostname=$target"

            return 0
        fi

        cmd=(
            ncat
            --send-only
            --wait 3s
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
            --wait 3s
            "$SERVER_IP"
            "$SERVER_PORT"
        )
    fi

    printf '%s\n' "$block_result" |
        "${cmd[@]}" 2>/dev/null

    rc=$?

    if [[ "$rc" -eq 0 ]]; then
        log "CONTROL_RESULT_SEND" \
            "status=SUCCESS destination=$target:$SERVER_PORT tls=$TLS_ENABLE"

        return 0
    fi

    log "CONTROL_RESULT_SEND" \
        "status=FAIL destination=$target:$SERVER_PORT tls=$TLS_ENABLE rc=$rc"

    # Komunikacijski problem ne smije ugasiti NIDS control proces.
    return 0
}


# --------------------------------------------------
# Obrada control poruka
# --------------------------------------------------

handle_control_message() {
    local message="$1"

    local command
    local incident_id
    local src_ip
    local ttl
    local rc
    local status
    local block_result
    local expired_result
    local unblock_rc

    read -r command incident_id src_ip ttl <<< "$message"

    case "$command" in

        # --------------------------------------------------
        # Normalna blokada koju naređuje centralni server
        # --------------------------------------------------

        BLOCK_REQUEST)

            if [[ -z "$incident_id" ||
                  -z "$src_ip" ||
                  -z "$ttl" ]]; then

                log "WARNING" \
                    "Neispravan BLOCK_REQUEST: $message"

                return 0
            fi

            log "BLOCK_REQUEST" \
                "incident_id=$incident_id src_ip=$src_ip ttl=$ttl"

            block_ip_once "$src_ip"
            rc=$?

            case "$rc" in

                0)
                    status="SUCCESS"

                    log "BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl"
                    ;;

                10)
                    status="EXISTS"

                    log "BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl"
                    ;;

                2)
                    status="INVALID_INPUT"

                    log "BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl"
                    ;;

                *)
                    status="FAIL"

                    log "BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl rc=$rc"
                    ;;
            esac

            block_result="BLOCK_RESULT nids incident_id=$incident_id src=$src_ip status=$status"

            log "CONTROL_RESULT" "$block_result"

            send_block_result_to_server "$block_result"

            if [[ "$status" == "SUCCESS" ||
                  "$status" == "EXISTS" ]]; then

                (
                    sleep "$ttl"

                    if unblock_ip "$src_ip"; then

                        expired_result="BLOCK_RESULT nids incident_id=$incident_id src=$src_ip status=EXPIRED"

                        log "BLOCK_EXPIRED" \
                            "incident_id=$incident_id src_ip=$src_ip ttl=$ttl"

                        log "CONTROL_RESULT" "$expired_result"

                        send_block_result_to_server "$expired_result"

                    else
                        unblock_rc=$?

                        log "WARNING" \
                            "BLOCK_EXPIRE_FAIL incident_id=$incident_id src_ip=$src_ip ttl=$ttl rc=$unblock_rc"
                    fi
                ) &
            fi
            ;;


        # --------------------------------------------------
        # Emergency fail-safe blokada
        #
        # Ovu naredbu smije pokrenuti lokalni NIDS kada:
        #
        # - detektira ICMP flood prema centralnom serveru
        # - NIDS_ALERT nije moguće dostaviti serveru
        # - dodatna provjera potvrdi da server nije dostupan
        #
        # Koristi zasebno firewall pravilo kako se emergency
        # TTL ne bi miješao s normalnim BLOCK_REQUEST pravilom.
        # --------------------------------------------------

        EMERGENCY_BLOCK_REQUEST)

            if [[ -z "$incident_id" ||
                  -z "$src_ip" ||
                  -z "$ttl" ]]; then

                log "WARNING" \
                    "Neispravan EMERGENCY_BLOCK_REQUEST: $message"

                return 0
            fi

            log "EMERGENCY_BLOCK_REQUEST" \
                "incident_id=$incident_id src_ip=$src_ip ttl=$ttl"

            block_ip_once \
                "$src_ip" \
                "$EMERGENCY_FIREWALL_COMMENT"

            rc=$?

            case "$rc" in

                0)
                    status="SUCCESS"

                    log "EMERGENCY_BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl"
                    ;;

                10)
                    status="EXISTS"

                    log "EMERGENCY_BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl"
                    ;;

                2)
                    status="INVALID_INPUT"

                    log "EMERGENCY_BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl"
                    ;;

                *)
                    status="FAIL"

                    log "EMERGENCY_BLOCK_ACTION" \
                        "status=$status incident_id=$incident_id src_ip=$src_ip ttl=$ttl rc=$rc"
                    ;;
            esac

            # Timer pokrećemo samo kada smo upravo dodali novo
            # emergency pravilo.
            #
            # Ako pravilo već postoji (EXISTS), njegov postojeći
            # timer ostaje odgovoran za uklanjanje pravila.
            # Time izbjegavamo da više paralelnih timera prerano
            # ukloni istu blokadu.
            if [[ "$status" == "SUCCESS" ]]; then

                (
                    sleep "$ttl"

                    if unblock_ip \
                        "$src_ip" \
                        "$EMERGENCY_FIREWALL_COMMENT"; then

                        log "EMERGENCY_BLOCK_EXPIRED" \
                            "incident_id=$incident_id src_ip=$src_ip ttl=$ttl"

                    else
                        unblock_rc=$?

                        log "WARNING" \
                            "EMERGENCY_BLOCK_EXPIRE_FAIL incident_id=$incident_id src_ip=$src_ip ttl=$ttl rc=$unblock_rc"
                    fi
                ) &
            fi
            ;;


        # --------------------------------------------------
        # Testna control poruka
        # --------------------------------------------------

        TEST_CONTROL)

            log "CONTROL" \
                "Primljena testna poruka: $message"
            ;;


        *)

            log "WARNING" \
                "Nepoznata control naredba: $message"
            ;;
    esac
}


# --------------------------------------------------
# Signal handling
# --------------------------------------------------

trap cleanup SIGINT SIGTERM EXIT


# --------------------------------------------------
# Ncat control listener
# --------------------------------------------------

log "INFO" \
    "Pokrecem NIDS control listener na $CONTROL_IP:$CONTROL_PORT (TLS=$TLS_ENABLE)"


while true; do

    MESSAGE_FILE="$(mktemp)"

    if [[ "$TLS_ENABLE" == "1" ]]; then

        ncat \
            -l "$CONTROL_IP" "$CONTROL_PORT" \
            --ssl \
            --ssl-cert "$TLS_CERT" \
            --ssl-key "$TLS_KEY" \
            > "$MESSAGE_FILE" 2>/dev/null &

    else

        ncat \
            -l "$CONTROL_IP" "$CONTROL_PORT" \
            > "$MESSAGE_FILE" 2>/dev/null &
    fi

    NCAT_PID=$!

    wait "$NCAT_PID" || true
    NCAT_PID=""

    message="$(cat "$MESSAGE_FILE")"

    rm -f "$MESSAGE_FILE"
    MESSAGE_FILE=""

    if [[ -n "$message" ]]; then
        handle_control_message "$message"
    fi
done