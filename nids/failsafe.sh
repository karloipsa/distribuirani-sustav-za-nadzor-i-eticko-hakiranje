#!/usr/bin/env bash

: "${EMERGENCY_BLOCK_ENABLE:=0}"
: "${EMERGENCY_BLOCK_TTL:=60}"
: "${SERVER_CHECK_RETRIES:=2}"
: "${SERVER_CHECK_WAIT:=1}"

if ! [[ "$EMERGENCY_BLOCK_ENABLE" =~ ^[01]$ ]]; then
    EMERGENCY_BLOCK_ENABLE=0
fi

if ! [[ "$EMERGENCY_BLOCK_TTL" =~ ^[0-9]+$ ]] ||
   (( EMERGENCY_BLOCK_TTL < 1 )); then
    EMERGENCY_BLOCK_TTL=60
fi

if ! [[ "$SERVER_CHECK_RETRIES" =~ ^[0-9]+$ ]] ||
   (( SERVER_CHECK_RETRIES < 1 )); then
    SERVER_CHECK_RETRIES=2
fi

if ! [[ "$SERVER_CHECK_WAIT" =~ ^[0-9]+$ ]]; then
    SERVER_CHECK_WAIT=1
fi

server_port_reachable() {
    ncat -z -w 1 "$SERVER_IP" "$SERVER_PORT" >/dev/null 2>&1
}

confirm_server_unavailable() {
    local attempt

    for (( attempt=1; attempt<=SERVER_CHECK_RETRIES; attempt++ )); do
        if server_port_reachable; then
            log "FAILSAFE_CHECK" \
                "server=$SERVER_IP:$SERVER_PORT status=REACHABLE attempt=$attempt/$SERVER_CHECK_RETRIES"
            return 1
        fi

        log "FAILSAFE_CHECK" \
            "server=$SERVER_IP:$SERVER_PORT status=UNREACHABLE attempt=$attempt/$SERVER_CHECK_RETRIES"

        if (( attempt < SERVER_CHECK_RETRIES )); then
            sleep "$SERVER_CHECK_WAIT"
        fi
    done

    return 0
}

send_emergency_block_request() {
    local incident_id="$1"
    local src_ip="$2"
    local ttl="$3"
    local target="$CONTROL_IP"
    local cmd

    if [[ "$TLS_ENABLE" == "1" ]]; then
        target="nids"

        if ! getent hosts "$target" >/dev/null 2>&1; then
            log "ERROR" \
                "FAILSAFE TLS hostname 'nids' nije moguće razriješiti"
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
            "$CONTROL_PORT"
        )
    else
        cmd=(
            ncat
            --send-only
            --wait 2s
            "$CONTROL_IP"
            "$CONTROL_PORT"
        )
    fi

    if printf '%s\n' \
        "EMERGENCY_BLOCK_REQUEST $incident_id $src_ip $ttl" |
        "${cmd[@]}" 2>/dev/null; then

        log "FAILSAFE" \
            "EMERGENCY_BLOCK_REQUEST poslan src=$src_ip ttl=$ttl destination=$target:$CONTROL_PORT"
        return 0
    fi

    log "ERROR" \
        "FAILSAFE EMERGENCY_BLOCK_REQUEST nije moguće poslati src=$src_ip destination=$target:$CONTROL_PORT"
    return 1
}

handle_server_failsafe() {
    local src_ip="$1"
    local dst_ip="$2"
    local now
    local incident_id

    [[ "$EMERGENCY_BLOCK_ENABLE" == "1" ]] || return 0
    [[ "$dst_ip" == "$SERVER_IP" ]] || return 0

    log "FAILSAFE" \
        "state=SERVER_ATTACK_ALERT_DELIVERY_FAILED src=$src_ip dst=$dst_ip"

    if ! confirm_server_unavailable; then
        log "FAILSAFE" \
            "action=NO_BLOCK src=$src_ip dst=$dst_ip reason=SERVER_PORT_REACHABLE"
        return 0
    fi

    now="$(date +%s)"
    incident_id="emergency-icmp-${now}-${src_ip//./_}-${dst_ip//./_}"

    log "FAILSAFE" \
        "action=EMERGENCY_BLOCK src=$src_ip dst=$dst_ip incident_id=$incident_id ttl=${EMERGENCY_BLOCK_TTL}s reason=SERVER_UNAVAILABLE_UNDER_ATTACK"

    if ! send_emergency_block_request \
        "$incident_id" \
        "$src_ip" \
        "$EMERGENCY_BLOCK_TTL"; then

        log "ERROR" \
            "FAILSAFE action=EMERGENCY_BLOCK_FAILED src=$src_ip dst=$dst_ip incident_id=$incident_id"
    fi

    return 0
}