#!/usr/bin/env bash

FIREWALL_COMMENT="diplomski-nids"
EMERGENCY_FIREWALL_COMMENT="diplomski-nids-emergency"


block_ip_once() {
    local src_ip="$1"
    local comment="${2:-$FIREWALL_COMMENT}"

    # Source IP mora postojati.
    if [[ -z "$src_ip" ]]; then
        return 2
    fi

    # Osnovni IPv4 format: četiri numerička okteta.
    if [[ ! "$src_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 2
    fi

    # Svaki IPv4 oktet mora biti u rasponu 0-255.
    local o1 o2 o3 o4 octet
    IFS='.' read -r o1 o2 o3 o4 <<< "$src_ip"

    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if (( 10#$octet > 255 )); then
            return 2
        fi
    done

    # Provjeri postoji li već DROP pravilo s istom oznakom.
    if iptables -C FORWARD \
        -s "$src_ip" \
        -m comment --comment "$comment" \
        -j DROP 2>/dev/null; then

        return 10
    fi

    # Dodaj pravilo na početak FORWARD lanca.
    if iptables -I FORWARD 1 \
        -s "$src_ip" \
        -m comment --comment "$comment" \
        -j DROP; then

        return 0
    fi

    return 1
}


unblock_ip() {
    local src_ip="$1"
    local comment="${2:-$FIREWALL_COMMENT}"

    if [[ -z "$src_ip" ]]; then
        return 2
    fi

    if [[ ! "$src_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 2
    fi

    local o1 o2 o3 o4 octet
    IFS='.' read -r o1 o2 o3 o4 <<< "$src_ip"

    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if (( 10#$octet > 255 )); then
            return 2
        fi
    done

    if iptables -C FORWARD \
        -s "$src_ip" \
        -m comment --comment "$comment" \
        -j DROP 2>/dev/null; then

        iptables -D FORWARD \
            -s "$src_ip" \
            -m comment --comment "$comment" \
            -j DROP

        return $?
    fi

    return 10
}