#!/usr/bin/env bash
set -euo pipefail

umask 077

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONF="$BASE/server.conf"
AUTH_LIST="$BASE/dozvoljeni_agenti.txt"

CA_DIR="$BASE/ca"
CA_KEY="$CA_DIR/ca-key.pem"
CA_CERT="$CA_DIR/ca-cert.pem"
ISSUED_DIR="$CA_DIR/issued"

CA_DAYS=3650
CERT_DAYS=825


# --------------------------------------------------
# Pomoćne funkcije
# --------------------------------------------------

conf_val() {
    local key="$1"

    awk -v k="$key" '
        $1 == k ":" {
            print $2
            exit
        }
    ' "$CONF" 2>/dev/null || true
}


validate_ipv4() {
    local ip="$1"
    local o1 o2 o3 o4 octet

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if (( 10#$octet > 255 )); then
            return 1
        fi
    done

    return 0
}


expected_ip_for_node() {
    local node_id="$1"
    local agent_id
    local agent_ip

    # Server
    if [[ "$node_id" == "server" ]]; then
        conf_val server_ip
        return 0
    fi

    # NIDS
    if [[ "$node_id" == "nids" ]]; then
        conf_val nids_control_ip
        return 0
    fi

    # Agenti
    while read -r agent_id agent_ip || [[ -n "${agent_id:-}" ]]; do
        [[ -z "${agent_id:-}" ]] && continue
        [[ "$agent_id" == \#* ]] && continue

        if [[ "$agent_id" == "$node_id" ]]; then
            printf '%s\n' "$agent_ip"
            return 0
        fi

    done < "$AUTH_LIST"

    return 1
}


# --------------------------------------------------
# Inicijalizacija CA-a
# --------------------------------------------------

init_ca() {
    mkdir -p "$CA_DIR" "$ISSUED_DIR"

    if [[ -f "$CA_KEY" && -f "$CA_CERT" ]]; then
        echo "[INFO] Lokalni CA već postoji."
        return 0
    fi

    if [[ -f "$CA_KEY" || -f "$CA_CERT" ]]; then
        echo "[ERROR] CA stanje je nepotpuno."
        echo "        Očekujem i ca-key.pem i ca-cert.pem."
        return 1
    fi

    echo "[INFO] Generiram lokalni CA."

    openssl genpkey \
        -algorithm RSA \
        -pkeyopt rsa_keygen_bits:3072 \
        -out "$CA_KEY"

    openssl req \
        -x509 \
        -new \
        -sha256 \
        -key "$CA_KEY" \
        -out "$CA_CERT" \
        -days "$CA_DAYS" \
        -subj "/C=HR/O=FOI/OU=Diplomski/CN=Diplomski Local CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash"

    chmod 600 "$CA_KEY"
    chmod 644 "$CA_CERT"

    echo "[PASS] Lokalni CA generiran."
}


# --------------------------------------------------
# Potpisivanje CSR-a
# --------------------------------------------------

sign_csr() {
    local node_id="$1"
    local csr_file="$2"

    local node_ip
    local cert_file
    local ext_file
    local serial

    if [[ ! -f "$csr_file" ]]; then
        echo "[ERROR] CSR ne postoji: $csr_file"
        return 1
    fi

    node_ip="$(expected_ip_for_node "$node_id" || true)"

    if [[ -z "$node_ip" ]]; then
        echo "[ERROR] Čvor nije autoriziran: $node_id"
        return 1
    fi

    if ! validate_ipv4 "$node_ip"; then
        echo "[ERROR] Neispravan IP za $node_id: $node_ip"
        return 1
    fi

    if ! openssl req \
        -in "$csr_file" \
        -noout \
        -verify >/dev/null 2>&1; then

        echo "[ERROR] CSR nije valjan: $csr_file"
        return 1
    fi

    mkdir -p "$ISSUED_DIR"

    cert_file="$ISSUED_DIR/${node_id}-cert.pem"
    ext_file="$(mktemp)"

    cat > "$ext_file" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${node_id},IP:${node_ip}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

    serial="0x$(openssl rand -hex 16)"

    if ! openssl x509 \
        -req \
        -sha256 \
        -in "$csr_file" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -set_serial "$serial" \
        -out "$cert_file" \
        -days "$CERT_DAYS" \
        -extfile "$ext_file"; then

        rm -f "$ext_file"
        echo "[ERROR] Potpisivanje certifikata nije uspjelo."
        return 1
    fi

    rm -f "$ext_file"

    chmod 644 "$cert_file"

    if ! openssl verify \
        -CAfile "$CA_CERT" \
        -verify_ip "$node_ip" \
        "$cert_file" >/dev/null 2>&1; then

        echo "[ERROR] Završna provjera certifikata nije uspjela."
        rm -f "$cert_file"
        return 1
    fi

    echo "[PASS] Certifikat izdan:"
    echo "       node=$node_id"
    echo "       ip=$node_ip"
    echo "       cert=$cert_file"
}


# --------------------------------------------------
# Glavni poziv
# --------------------------------------------------

usage() {
    echo "Upotreba:"
    echo "  $0 init"
    echo "  $0 sign <node_id> <csr_file>"
}


if [[ ! -f "$CONF" ]]; then
    echo "[ERROR] Nedostaje $CONF"
    exit 1
fi

if [[ ! -f "$AUTH_LIST" ]]; then
    echo "[ERROR] Nedostaje $AUTH_LIST"
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "[ERROR] openssl nije dostupan."
    exit 1
fi


case "${1:-}" in

    init)
        init_ca
        ;;

    sign)
        if [[ $# -ne 3 ]]; then
            usage
            exit 1
        fi

        init_ca
        sign_csr "$2" "$3"
        ;;

    *)
        usage
        exit 1
        ;;
esac