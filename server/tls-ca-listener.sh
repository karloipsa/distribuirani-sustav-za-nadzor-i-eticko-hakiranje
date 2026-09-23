#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_SCRIPT="$BASE/config.sh"
CA_SCRIPT="$BASE/tls-ca.sh"

# --------------------------------------------------
# Provjera osnovnih datoteka
# --------------------------------------------------

if [[ ! -f "$CONFIG_SCRIPT" ]]; then
    echo "[ERROR] Nedostaje config.sh"
    exit 1
fi

if [[ ! -x "$CA_SCRIPT" ]]; then
    echo "[ERROR] tls-ca.sh ne postoji ili nije izvršan"
    exit 1
fi

source "$CONFIG_SCRIPT"
init_config "$BASE"

TLS_CA_LOG="$LOG_DIR/tls-ca.log"

CA_CERT="$BASE/ca/ca-cert.pem"
ISSUED_DIR="$BASE/ca/issued"


# --------------------------------------------------
# Logiranje
#
# VAŽNO:
# Handlerov stdout ide natrag klijentu preko Ncata.
# Zato logove pišemo direktno u datoteku.
# --------------------------------------------------

tls_log() {
    local level="$1"
    shift

    mkdir -p "$LOG_DIR"

    printf '[%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$level" \
        "$*" \
        >> "$TLS_CA_LOG"
}


# --------------------------------------------------
# Očekivani IP čvora
# --------------------------------------------------

expected_ip_for_node() {
    local node_id="$1"

    # NIDS
    if [[ "$node_id" == "nids" ]]; then
        printf '%s\n' "$NIDS_CONTROL_IP"
        return 0
    fi

    # Agenti
    awk -v node="$node_id" '
        $1 == node {
            print $2
            found=1
            exit
        }

        END {
            if (!found)
                exit 1
        }
    ' "$AUTH_LIST"
}


# --------------------------------------------------
# CERT_ERROR odgovor
# --------------------------------------------------

send_error() {
    local reason="$1"

    printf 'CERT_ERROR reason=%s\n' "$reason"
}


# --------------------------------------------------
# Obrada jedne enrollment veze
# --------------------------------------------------

handle_connection() {
    local remote_ip="${NCAT_REMOTE_ADDR:-UNKNOWN}"

    local header
    local command
    local node_id
    local extra

    local expected_ip
    local csr_file
    local sign_log
    local cert_file

    csr_file="$(mktemp)"
    sign_log="$(mktemp)"

    trap "rm -f -- '$csr_file' '$sign_log'" EXIT


    # --------------------------------------------------
    # Zaglavlje zahtjeva
    #
    # Očekujemo:
    #
    # CERT_REQUEST agent-01
    #
    # Nakon prve linije slijedi PEM CSR.
    # --------------------------------------------------

    if ! IFS= read -r header; then
        tls_log WARNING \
            "Prazan enrollment zahtjev remote_ip=$remote_ip"

        send_error "EMPTY_REQUEST"
        return 0
    fi

    read -r command node_id extra <<< "$header"


    # --------------------------------------------------
    # Provjera protokola
    # --------------------------------------------------

    if [[ "$command" != "CERT_REQUEST" ]]; then
        tls_log WARNING \
            "Nepoznata TLS enrollment naredba remote_ip=$remote_ip header='$header'"

        send_error "INVALID_COMMAND"
        return 0
    fi

    if [[ -z "${node_id:-}" || -n "${extra:-}" ]]; then
        tls_log WARNING \
            "Neispravan CERT_REQUEST remote_ip=$remote_ip header='$header'"

        send_error "INVALID_REQUEST"
        return 0
    fi

    # Dozvoljavamo samo jednostavne ID-eve.
    if [[ ! "$node_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        tls_log WARNING \
            "Neispravan node_id remote_ip=$remote_ip node_id='$node_id'"

        send_error "INVALID_NODE_ID"
        return 0
    fi


    # --------------------------------------------------
    # Autorizacija čvora
    # --------------------------------------------------

    expected_ip="$(
        expected_ip_for_node "$node_id" 2>/dev/null ||
        true
    )"

    if [[ -z "$expected_ip" ]]; then
        tls_log WARNING \
            "Neautorizirani enrollment remote_ip=$remote_ip node_id=$node_id"

        send_error "UNAUTHORIZED_NODE"
        return 0
    fi


    # --------------------------------------------------
    # Provjera izvornog IP-a
    #
    # agent-01 se npr. smije enrolati samo ako zahtjev
    # stvarno dolazi s njegove očekivane IPv4 adrese.
    # --------------------------------------------------

    if [[ "$remote_ip" != "$expected_ip" ]]; then
        tls_log WARNING \
            "Enrollment IP mismatch node_id=$node_id remote_ip=$remote_ip expected_ip=$expected_ip"

        send_error "SOURCE_IP_MISMATCH"
        return 0
    fi


    # --------------------------------------------------
    # Primanje CSR-a
    # --------------------------------------------------

    local csr_complete=0
    local csr_line

    while IFS= read -r csr_line; do
        printf '%s\n' "$csr_line" >> "$csr_file"

        if [[ "$csr_line" == "-----END CERTIFICATE REQUEST-----" ]]; then
            csr_complete=1
            break
        fi
    done

    if [[ "$csr_complete" -ne 1 ]]; then
        tls_log WARNING \
            "Nepotpun CSR node_id=$node_id remote_ip=$remote_ip"

        send_error "INCOMPLETE_CSR"
        return 0
    fi

    if [[ ! -s "$csr_file" ]]; then
        tls_log WARNING \
            "Prazan CSR node_id=$node_id remote_ip=$remote_ip"

        send_error "EMPTY_CSR"
        return 0
    fi


    # --------------------------------------------------
    # Osnovna CSR provjera
    # --------------------------------------------------

    if ! openssl req \
        -in "$csr_file" \
        -noout \
        -verify >/dev/null 2>&1; then

        tls_log WARNING \
            "Neispravan CSR node_id=$node_id remote_ip=$remote_ip"

        send_error "INVALID_CSR"
        return 0
    fi


    # --------------------------------------------------
    # Potpisivanje preko tls-ca.sh
    # --------------------------------------------------

    if ! "$CA_SCRIPT" \
        sign \
        "$node_id" \
        "$csr_file" \
        >"$sign_log" 2>&1; then

        tls_log ERROR \
            "Potpisivanje nije uspjelo node_id=$node_id remote_ip=$remote_ip details='$(tr '\n' ' ' < "$sign_log")'"

        send_error "SIGN_FAILED"
        return 0
    fi

    cert_file="$ISSUED_DIR/${node_id}-cert.pem"

    if [[ ! -f "$cert_file" ]]; then
        tls_log ERROR \
            "Potpisivanje prijavilo uspjeh, ali certifikat ne postoji node_id=$node_id"

        send_error "CERT_NOT_CREATED"
        return 0
    fi

    if [[ ! -f "$CA_CERT" ]]; then
        tls_log ERROR \
            "CA certifikat nedostaje"

        send_error "CA_CERT_MISSING"
        return 0
    fi


    # --------------------------------------------------
    # Uspješan odgovor
    #
    # Privatni ključ se NE šalje.
    #
    # Vraćamo:
    #   - potpisani certifikat čvora
    #   - javni CA certifikat
    # --------------------------------------------------

    tls_log INFO \
        "CERT_ISSUED node_id=$node_id remote_ip=$remote_ip cert=$cert_file"

    printf 'CERT_RESPONSE %s\n' "$node_id"

    printf 'CERT_BEGIN\n'
    cat "$cert_file"
    printf 'CERT_END\n'

    printf 'CA_BEGIN\n'
    cat "$CA_CERT"
    printf 'CA_END\n'
}


# --------------------------------------------------
# Izgradnja Ncat allow liste
# --------------------------------------------------

build_allow_list() {
    local agent_ips

    agent_ips="$(
        awk '
            NF >= 2 && $1 !~ /^#/ {
                print $2
            }
        ' "$AUTH_LIST" |
        paste -sd, -
    )"

    if [[ -n "$agent_ips" ]]; then
        printf '%s,%s\n' \
            "$agent_ips" \
            "$NIDS_CONTROL_IP"
    else
        printf '%s\n' "$NIDS_CONTROL_IP"
    fi
}


# --------------------------------------------------
# Pokretanje listenera
# --------------------------------------------------

start_listener() {
    local allow_list

    if ! command -v ncat >/dev/null 2>&1; then
        echo "[ERROR] ncat nije dostupan."
        exit 1
    fi

    # CA mora postojati prije listenera.
    "$CA_SCRIPT" init >/dev/null

    allow_list="$(build_allow_list)"

    tls_log INFO \
        "Pokrećem TLS CA enrollment listener address=$SERVER_IP port=$TLS_CA_PORT allow=$allow_list"

    echo "[INFO] TLS CA listener:"
    echo "       $SERVER_IP:$TLS_CA_PORT"
    echo "       allow=$allow_list"

    exec ncat \
        -4 \
        --listen \
        "$SERVER_IP" \
        "$TLS_CA_PORT" \
        --keep-open \
        --max-conns 20 \
        --allow "$allow_list" \
        --exec "$BASE/tls-ca-listener.sh handle"
}


# --------------------------------------------------
# Glavni poziv
# --------------------------------------------------

case "${1:-}" in

    start)
        start_listener
        ;;

    handle)
        handle_connection
        ;;

    *)
        echo "Upotreba:"
        echo "  $0 start"
        exit 1
        ;;
esac