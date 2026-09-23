#!/usr/bin/env bash
set -euo pipefail

umask 077

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$BASE/agent.conf"
SSL_DIR="$BASE/ssl"


# --------------------------------------------------
# Pomoćne funkcije
# --------------------------------------------------

read_conf() {
    local expr="$1"

    yq e -r "$expr" "$CONF" 2>/dev/null || true
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


# --------------------------------------------------
# Provjera preduvjeta
# --------------------------------------------------

for cmd in openssl yq ncat timeout; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Nedostaje naredba: $cmd"
        exit 1
    fi
done

if [[ ! -f "$CONF" ]]; then
    echo "[ERROR] Nedostaje agent.conf:"
    echo "        $CONF"
    exit 1
fi


# --------------------------------------------------
# Učitavanje konfiguracije
# --------------------------------------------------

AGENT_ID="$(read_conf '.id')"
SERVER_IP="$(read_conf '.server_ip')"

# Ako tls.ca_port još nije dodan u agent.conf,
# koristi trenutni enrollment port 5002.
TLS_CA_PORT="$(read_conf '.tls.ca_port // 5002')"


if [[ -z "$AGENT_ID" || "$AGENT_ID" == "null" ]]; then
    echo "[ERROR] Agent ID nije definiran u agent.conf"
    exit 1
fi

if [[ ! "$AGENT_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[ERROR] Neispravan agent ID: $AGENT_ID"
    exit 1
fi

if [[ -z "$SERVER_IP" || "$SERVER_IP" == "null" ]]; then
    echo "[ERROR] server_ip nije definiran u agent.conf"
    exit 1
fi

if ! validate_ipv4 "$SERVER_IP"; then
    echo "[ERROR] Neispravan server_ip: $SERVER_IP"
    exit 1
fi

if [[ ! "$TLS_CA_PORT" =~ ^[0-9]+$ ]] ||
   (( TLS_CA_PORT < 1 || TLS_CA_PORT > 65535 )); then

    echo "[ERROR] Neispravan TLS CA port: $TLS_CA_PORT"
    exit 1
fi


# --------------------------------------------------
# TLS putanje
# --------------------------------------------------

KEY_FILE="$SSL_DIR/${AGENT_ID}-key.pem"
CSR_FILE="$SSL_DIR/${AGENT_ID}.csr"
CERT_FILE="$SSL_DIR/${AGENT_ID}-cert.pem"
CA_FILE="$SSL_DIR/ca-cert.pem"


# --------------------------------------------------
# Generiranje privatnog ključa i CSR-a
# --------------------------------------------------

prepare_enrollment() {

    mkdir -p "$SSL_DIR"

    if [[ -f "$KEY_FILE" ]]; then

        if ! openssl pkey \
            -in "$KEY_FILE" \
            -check \
            -noout >/dev/null 2>&1; then

            echo "[ERROR] Postojeći privatni ključ nije valjan:"
            echo "        $KEY_FILE"
            exit 1
        fi

        chmod 600 "$KEY_FILE"

        echo "[INFO] Privatni ključ već postoji:"
        echo "       $KEY_FILE"

    else

        echo "[INFO] Generiram privatni ključ za $AGENT_ID"

        openssl genpkey \
            -algorithm RSA \
            -pkeyopt rsa_keygen_bits:2048 \
            -out "$KEY_FILE"

        chmod 600 "$KEY_FILE"

        echo "[PASS] Privatni ključ generiran."
    fi


    echo "[INFO] Generiram CSR za $AGENT_ID"

    openssl req \
        -new \
        -sha256 \
        -key "$KEY_FILE" \
        -out "$CSR_FILE" \
        -subj "/C=HR/O=FOI/OU=Diplomski IDPS/CN=$AGENT_ID"

    chmod 644 "$CSR_FILE"


    if ! openssl req \
        -in "$CSR_FILE" \
        -noout \
        -verify >/dev/null 2>&1; then

        echo "[ERROR] Generirani CSR nije valjan."
        exit 1
    fi


    echo "[PASS] CSR generiran i verificiran."
}


# --------------------------------------------------
# Mrežni enrollment
# --------------------------------------------------

enroll_certificate() {

    local temp_dir
    local response_file
    local temp_cert
    local temp_ca
    local first_line

    prepare_enrollment

    temp_dir="$(mktemp -d)"
    response_file="$temp_dir/response.txt"
    temp_cert="$temp_dir/cert.pem"
    temp_ca="$temp_dir/ca-cert.pem"

    # U trap spremamo konkretnu putanju, ne lokalnu varijablu.
    trap "rm -rf -- '$temp_dir'" EXIT


    echo
    echo "[INFO] Šaljem CSR serveru:"
    echo "       $SERVER_IP:$TLS_CA_PORT"


    # --------------------------------------------------
    # CERT_REQUEST
    # --------------------------------------------------

    if ! {
        printf 'CERT_REQUEST %s\n' "$AGENT_ID"
        cat "$CSR_FILE"
    } |
        timeout 15 \
        ncat \
            --no-shutdown \
            "$SERVER_IP" \
            "$TLS_CA_PORT" \
            > "$response_file"; then

        echo "[ERROR] Enrollment komunikacija sa serverom nije uspjela."
        exit 1
    fi


    if [[ ! -s "$response_file" ]]; then
        echo "[ERROR] Server nije vratio enrollment odgovor."
        exit 1
    fi


    first_line="$(head -n 1 "$response_file" | tr -d '\r')"


    # --------------------------------------------------
    # Server je odbio zahtjev
    # --------------------------------------------------

    if [[ "$first_line" == CERT_ERROR* ]]; then
        echo "[ERROR] Server je odbio enrollment:"
        echo "        $first_line"
        exit 1
    fi


    # --------------------------------------------------
    # Provjera CERT_RESPONSE zaglavlja
    # --------------------------------------------------

    if [[ "$first_line" != "CERT_RESPONSE $AGENT_ID" ]]; then
        echo "[ERROR] Neočekivani odgovor servera:"
        echo "        $first_line"
        exit 1
    fi


    # --------------------------------------------------
    # Izdvajanje certifikata
    # --------------------------------------------------

    awk '
        /^CERT_BEGIN$/ {
            inside=1
            next
        }

        /^CERT_END$/ {
            inside=0
            exit
        }

        inside {
            print
        }
    ' "$response_file" > "$temp_cert"


    # --------------------------------------------------
    # Izdvajanje CA certifikata
    # --------------------------------------------------

    awk '
        /^CA_BEGIN$/ {
            inside=1
            next
        }

        /^CA_END$/ {
            inside=0
            exit
        }

        inside {
            print
        }
    ' "$response_file" > "$temp_ca"


    if [[ ! -s "$temp_cert" ]]; then
        echo "[ERROR] CERT_RESPONSE ne sadrži certifikat."
        exit 1
    fi

    if [[ ! -s "$temp_ca" ]]; then
        echo "[ERROR] CERT_RESPONSE ne sadrži CA certifikat."
        exit 1
    fi


    # --------------------------------------------------
    # Provjera PEM strukture
    # --------------------------------------------------

    if ! openssl x509 \
        -in "$temp_cert" \
        -noout >/dev/null 2>&1; then

        echo "[ERROR] Primljeni certifikat nije valjan X.509 certifikat."
        exit 1
    fi


    if ! openssl x509 \
        -in "$temp_ca" \
        -noout >/dev/null 2>&1; then

        echo "[ERROR] Primljeni CA certifikat nije valjan."
        exit 1
    fi


    # --------------------------------------------------
    # Provjera CA potpisa
    # --------------------------------------------------

    if ! openssl verify \
        -CAfile "$temp_ca" \
        "$temp_cert" >/dev/null 2>&1; then

        echo "[ERROR] Certifikat nije potpisan primljenim CA certifikatom."
        exit 1
    fi


    # --------------------------------------------------
    # Provjera da certifikat pripada našem privatnom ključu
    # --------------------------------------------------

    if ! cmp -s \
        <(
            openssl pkey \
                -in "$KEY_FILE" \
                -pubout 2>/dev/null
        ) \
        <(
            openssl x509 \
                -in "$temp_cert" \
                -pubkey \
                -noout 2>/dev/null
        ); then

        echo "[ERROR] Primljeni certifikat ne odgovara lokalnom privatnom ključu."
        exit 1
    fi


    # --------------------------------------------------
    # Spremanje tek nakon svih provjera
    # --------------------------------------------------

    install \
        -m 644 \
        "$temp_cert" \
        "$CERT_FILE"

    install \
        -m 644 \
        "$temp_ca" \
        "$CA_FILE"


    rm -rf "$temp_dir"
    trap - EXIT


    echo
    echo "[PASS] TLS enrollment uspješno završen."
    echo
    echo "Agent:"
    echo "  $AGENT_ID"
    echo
    echo "Privatni ključ:"
    echo "  $KEY_FILE"
    echo
    echo "Certifikat:"
    echo "  $CERT_FILE"
    echo
    echo "CA certifikat:"
    echo "  $CA_FILE"
}


# --------------------------------------------------
# Glavni poziv
# --------------------------------------------------

case "${1:-}" in

    prepare)
        prepare_enrollment
        ;;

    enroll)
        enroll_certificate
        ;;

    *)
        echo "Upotreba:"
        echo "  $0 prepare"
        echo "  $0 enroll"
        exit 1
        ;;
esac