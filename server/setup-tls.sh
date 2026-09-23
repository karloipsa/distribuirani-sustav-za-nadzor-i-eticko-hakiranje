#!/usr/bin/env bash
set -euo pipefail

umask 077

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_USER="${SSH_USER:-user}"

SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
SSH_PUB="$SSH_KEY.pub"

AGENT_REMOTE_DIR="/home/user/diplomski/agent"
NIDS_REMOTE_DIR="/home/user/diplomski/nids"

declare -A MGMT_IP=(
    [agent-01]="192.168.56.102"
    [agent-02]="192.168.56.103"
    [agent-03]="192.168.56.104"
    [nids]="192.168.56.106"
)

declare -A RUNTIME_IP=(
    [agent-01]="192.168.100.2"
    [agent-02]="192.168.100.3"
    [agent-03]="192.168.100.4"
    [nids]="192.168.100.254"
)

SSH_OPTS=(
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
)

LISTENER_STARTED=0
LISTENER_PID=""

info() {
    printf '[INFO] %s\n' "$*"
}

pass() {
    printf '[PASS] %s\n' "$*"
}

generated() {
    printf '[GENERATED] %s\n' "$*"
}

existing() {
    printf '[EXISTING] %s\n' "$*"
}

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}


bootstrap_ssh() {
    echo
    echo "===== SSH ORCHESTRATION ====="

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # ----------------------------------------------
    # Serverov orchestrator key
    # ----------------------------------------------

    if [[ -f "$SSH_KEY" || -f "$SSH_PUB" ]]; then

        if [[ ! -f "$SSH_KEY" || ! -f "$SSH_PUB" ]]; then
            fail "SSH keypair je nepotpun: $SSH_KEY / $SSH_PUB"
        fi

        if ! ssh-keygen -y \
            -f "$SSH_KEY" \
            >/dev/null 2>&1; then

            fail "Postojeci SSH privatni kljuc nije valjan"
        fi

        chmod 600 "$SSH_KEY"
        chmod 644 "$SSH_PUB"

        existing "server SSH orchestrator key"

    else

        info "Generiram server SSH orchestrator key"

        ssh-keygen \
            -q \
            -t ed25519 \
            -f "$SSH_KEY" \
            -N "" \
            -C "diplomski-server-orchestrator"

        chmod 600 "$SSH_KEY"
        chmod 644 "$SSH_PUB"

        generated "server SSH orchestrator key"
    fi


    # ----------------------------------------------
    # Autorizacija na agentima i NIDS-u
    # ----------------------------------------------

    local node
    local mgmt_ip

    for node in agent-01 agent-02 agent-03 nids; do

        mgmt_ip="${MGMT_IP[$node]}"

        echo
        info "Provjeravam SSH pristup: $node ($mgmt_ip)"

        # Ako key-based SSH vec radi, ne diramo nista.
        if ssh \
            "${SSH_OPTS[@]}" \
            "$SSH_USER@$mgmt_ip" \
            'true' \
            >/dev/null 2>&1; then

            pass "$node SSH key vec autoriziran"
            continue
        fi

        info "$node jos nema autoriziran server SSH key"
        info "Ako bude zatrazena lozinka, unesi je jednom za $SSH_USER@$mgmt_ip"

        ssh-copy-id \
            -i "$SSH_PUB" \
            -o ConnectTimeout=8 \
            -o StrictHostKeyChecking=accept-new \
            "$SSH_USER@$mgmt_ip" ||
            fail "ssh-copy-id nije uspio za $node"


        # Nakon kopiranja lozinka vise ne smije biti potrebna.
        if ssh \
            "${SSH_OPTS[@]}" \
            "$SSH_USER@$mgmt_ip" \
            'true' \
            >/dev/null 2>&1; then

            pass "$node SSH key autoriziran"

        else

            fail "$node SSH pristup bez lozinke nije uspio"
        fi
    done

    echo
    pass "SSH orchestration spreman"
}

cleanup() {
    if [[ "$LISTENER_STARTED" == "1" &&
          -n "${LISTENER_PID:-}" ]]; then

        if kill -0 "$LISTENER_PID" 2>/dev/null; then
            info "Zaustavljam enrollment listener PID=$LISTENER_PID"
            kill "$LISTENER_PID" 2>/dev/null || true
            wait "$LISTENER_PID" 2>/dev/null || true
        fi
    fi
}

trap cleanup EXIT INT TERM


port_listening() {
    ss -lnt 2>/dev/null |
        awk 'NR > 1 {print $4}' |
        grep -Eq "(:|\])${TLS_CA_PORT}$"
}


server_cert_valid() {
    [[ -f "$SERVER_KEY" ]] || return 1
    [[ -f "$SERVER_CERT" ]] || return 1
    [[ -f "$CA_CERT" ]] || return 1

    openssl pkey \
        -in "$SERVER_KEY" \
        -check \
        -noout >/dev/null 2>&1 ||
        return 1

    openssl x509 \
        -in "$SERVER_CERT" \
        -checkend 0 \
        -noout >/dev/null 2>&1 ||
        return 1

    openssl verify \
        -CAfile "$CA_CERT" \
        -verify_hostname server \
        "$SERVER_CERT" >/dev/null 2>&1 ||
        return 1

    openssl verify \
        -CAfile "$CA_CERT" \
        -verify_ip "$SERVER_IP" \
        "$SERVER_CERT" >/dev/null 2>&1 ||
        return 1

    cmp -s \
        <(
            openssl pkey \
                -in "$SERVER_KEY" \
                -pubout 2>/dev/null
        ) \
        <(
            openssl x509 \
                -in "$SERVER_CERT" \
                -pubkey \
                -noout 2>/dev/null
        ) ||
        return 1

    return 0
}


prepare_server_identity() {
    echo
    echo "===== SERVER TLS IDENTITY ====="

    mkdir -p "$BASE/ssl" "$BASE/ca" "$BASE/log"

    bash "$BASE/tls-ca.sh" init

    [[ -f "$CA_CERT" ]] ||
        fail "CA certifikat nije generiran: $CA_CERT"

    if [[ -f "$SERVER_KEY" ]]; then

        if ! openssl pkey \
            -in "$SERVER_KEY" \
            -check \
            -noout >/dev/null 2>&1; then

            fail "Postojeci server privatni kljuc nije valjan"
        fi

        chmod 600 "$SERVER_KEY"

        existing "server privatni kljuc"

    else

        info "Generiram server privatni kljuc"

        openssl genpkey \
            -algorithm RSA \
            -pkeyopt rsa_keygen_bits:2048 \
            -out "$SERVER_KEY"

        chmod 600 "$SERVER_KEY"

        generated "server privatni kljuc"
    fi


    if server_cert_valid; then

        existing "server certifikat je valjan"

    else

        info "Generiram server CSR"

        openssl req \
            -new \
            -sha256 \
            -key "$SERVER_KEY" \
            -out "$SERVER_CSR" \
            -subj "/C=HR/O=FOI/OU=Diplomski IDPS/CN=server"

        openssl req \
            -in "$SERVER_CSR" \
            -verify \
            -noout >/dev/null 2>&1 ||
            fail "Server CSR nije valjan"

        bash "$BASE/tls-ca.sh" \
            sign \
            server \
            "$SERVER_CSR"

        [[ -f "$ISSUED_SERVER_CERT" ]] ||
            fail "CA nije izdao server certifikat"

        install \
            -m 644 \
            "$ISSUED_SERVER_CERT" \
            "$SERVER_CERT"

        generated "server certifikat"
    fi


    install \
        -m 644 \
        "$CA_CERT" \
        "$SERVER_CA"

    rm -f "$SERVER_CSR"

    server_cert_valid ||
        fail "Zavrsna provjera server certifikata nije prosla"

    pass "server TLS identitet"
}


start_ca_listener() {
    echo
    echo "===== TLS ENROLLMENT LISTENER ====="

    if port_listening; then
        existing "port $TLS_CA_PORT vec slusa; koristim postojeci listener"
        return 0
    fi

    chmod +x \
        "$BASE/tls-ca.sh" \
        "$BASE/tls-ca-listener.sh"

    info "Pokrecem CA enrollment listener na $SERVER_IP:$TLS_CA_PORT"

    "$BASE/tls-ca-listener.sh" start \
        >"$BASE/log/tls-ca-listener.out" \
        2>&1 &

    LISTENER_PID=$!
    LISTENER_STARTED=1

    for _ in {1..20}; do

        if port_listening; then
            pass "CA enrollment listener radi na portu $TLS_CA_PORT"
            return 0
        fi

        if ! kill -0 "$LISTENER_PID" 2>/dev/null; then

            echo
            echo "----- tls-ca-listener.out -----"
            tail -n 30 "$BASE/log/tls-ca-listener.out" 2>/dev/null || true

            fail "CA enrollment listener se ugasio"
        fi

        sleep 0.25
    done

    fail "Port $TLS_CA_PORT se nije otvorio"
}


setup_agent() {
    local node="$1"
    local mgmt_ip="${MGMT_IP[$node]}"
    local runtime_ip="${RUNTIME_IP[$node]}"

    echo
    echo "===== $node ====="

    ssh "${SSH_OPTS[@]}" \
        "$SSH_USER@$mgmt_ip" \
        bash -s -- \
        "$node" \
        "$runtime_ip" \
        "$AGENT_REMOTE_DIR" \
        "$CA_SHA" <<'REMOTE_AGENT'

set -euo pipefail

EXPECTED_ID="$1"
EXPECTED_IP="$2"
BASE="$3"
EXPECTED_CA_SHA="$4"

fail_remote() {
    echo "[FAIL] $*" >&2
    exit 1
}

cd "$BASE" ||
    fail_remote "Agent direktorij ne postoji: $BASE"

[[ -f agent.conf ]] ||
    fail_remote "Nedostaje agent.conf"

[[ -f tls-enroll.sh ]] ||
    fail_remote "Nedostaje tls-enroll.sh"

for cmd in openssl yq sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail_remote "Nedostaje naredba: $cmd"
done

ACTUAL_ID="$(yq e -r '.id' agent.conf)"
TLS_ENABLE="$(yq e -r '.tls.enable // 0' agent.conf)"

if [[ "$ACTUAL_ID" != "$EXPECTED_ID" ]]; then
    fail_remote \
        "agent.conf ID=$ACTUAL_ID, ocekivano=$EXPECTED_ID"
fi

if [[ "$TLS_ENABLE" != "1" ]]; then
    fail_remote \
        "TLS nije ukljucen u agent.conf za $EXPECTED_ID"
fi

KEY="ssl/${EXPECTED_ID}-key.pem"
CERT="ssl/${EXPECTED_ID}-cert.pem"
CA="ssl/ca-cert.pem"

CURRENT_CA_SHA=""

if [[ -f "$CA" ]]; then
    CURRENT_CA_SHA="$(sha256sum "$CA" | awk '{print $1}')"
fi

VALID=1

[[ -f "$KEY" ]]  || VALID=0
[[ -f "$CERT" ]] || VALID=0
[[ -f "$CA" ]]   || VALID=0

if [[ "$CURRENT_CA_SHA" != "$EXPECTED_CA_SHA" ]]; then
    VALID=0
fi

if [[ "$VALID" == "1" ]]; then

    openssl pkey \
        -in "$KEY" \
        -check \
        -noout >/dev/null 2>&1 ||
        VALID=0

    openssl x509 \
        -in "$CERT" \
        -checkend 0 \
        -noout >/dev/null 2>&1 ||
        VALID=0

    openssl verify \
        -CAfile "$CA" \
        -verify_ip "$EXPECTED_IP" \
        "$CERT" >/dev/null 2>&1 ||
        VALID=0
fi


if [[ "$VALID" == "1" ]]; then

    if ! cmp -s \
        <(openssl pkey -in "$KEY" -pubout 2>/dev/null) \
        <(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null); then

        VALID=0
    fi
fi


if [[ "$VALID" == "1" ]]; then
    echo "[EXISTING] $EXPECTED_ID TLS key/cert/CA su valjani"
    exit 0
fi


echo "[INFO] $EXPECTED_ID zahtijeva TLS enrollment"

bash -n tls-enroll.sh ||
    fail_remote "tls-enroll.sh syntax FAIL"

bash tls-enroll.sh enroll


NEW_CA_SHA="$(sha256sum "$CA" | awk '{print $1}')"

[[ "$NEW_CA_SHA" == "$EXPECTED_CA_SHA" ]] ||
    fail_remote "Primljeni CA nije serverov aktualni CA"

openssl verify \
    -CAfile "$CA" \
    -verify_ip "$EXPECTED_IP" \
    "$CERT" >/dev/null 2>&1 ||
    fail_remote "Certifikat ne vrijedi za $EXPECTED_IP"

cmp -s \
    <(openssl pkey -in "$KEY" -pubout 2>/dev/null) \
    <(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null) ||
    fail_remote "Certifikat ne odgovara privatnom kljucu"

echo "[PASS] $EXPECTED_ID TLS enrollment i verifikacija"

REMOTE_AGENT

    pass "$node"
}


setup_nids() {
    local mgmt_ip="${MGMT_IP[nids]}"
    local runtime_ip="${RUNTIME_IP[nids]}"

    echo
    echo "===== nids ====="

    ssh "${SSH_OPTS[@]}" \
        "$SSH_USER@$mgmt_ip" \
        bash -s -- \
        "$runtime_ip" \
        "$NIDS_REMOTE_DIR" \
        "$CA_SHA" <<'REMOTE_NIDS'

set -euo pipefail

EXPECTED_IP="$1"
BASE="$2"
EXPECTED_CA_SHA="$3"

fail_remote() {
    echo "[FAIL] $*" >&2
    exit 1
}

cd "$BASE" ||
    fail_remote "NIDS direktorij ne postoji: $BASE"

[[ -f nids.conf ]] ||
    fail_remote "Nedostaje nids.conf"

[[ -f tls-enroll.sh ]] ||
    fail_remote "Nedostaje tls-enroll.sh"

for cmd in openssl sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail_remote "Nedostaje naredba: $cmd"
done

source nids.conf

[[ "${CONTROL_IP:-}" == "$EXPECTED_IP" ]] ||
    fail_remote \
        "CONTROL_IP=${CONTROL_IP:-UNSET}, ocekivano=$EXPECTED_IP"

[[ "${TLS_ENABLE:-0}" == "1" ]] ||
    fail_remote "TLS nije ukljucen u nids.conf"

KEY="ssl/nids-key.pem"
CERT="ssl/nids-cert.pem"
CA="ssl/ca-cert.pem"

CURRENT_CA_SHA=""

if [[ -f "$CA" ]]; then
    CURRENT_CA_SHA="$(sha256sum "$CA" | awk '{print $1}')"
fi

VALID=1

[[ -f "$KEY" ]]  || VALID=0
[[ -f "$CERT" ]] || VALID=0
[[ -f "$CA" ]]   || VALID=0

if [[ "$CURRENT_CA_SHA" != "$EXPECTED_CA_SHA" ]]; then
    VALID=0
fi

if [[ "$VALID" == "1" ]]; then

    openssl pkey \
        -in "$KEY" \
        -check \
        -noout >/dev/null 2>&1 ||
        VALID=0

    openssl x509 \
        -in "$CERT" \
        -checkend 0 \
        -noout >/dev/null 2>&1 ||
        VALID=0

    openssl verify \
        -CAfile "$CA" \
        -verify_ip "$EXPECTED_IP" \
        "$CERT" >/dev/null 2>&1 ||
        VALID=0
fi


if [[ "$VALID" == "1" ]]; then

    if ! cmp -s \
        <(openssl pkey -in "$KEY" -pubout 2>/dev/null) \
        <(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null); then

        VALID=0
    fi
fi


if [[ "$VALID" == "1" ]]; then
    echo "[EXISTING] nids TLS key/cert/CA su valjani"
    exit 0
fi


echo "[INFO] nids zahtijeva TLS enrollment"

bash -n tls-enroll.sh ||
    fail_remote "tls-enroll.sh syntax FAIL"

bash tls-enroll.sh enroll


NEW_CA_SHA="$(sha256sum "$CA" | awk '{print $1}')"

[[ "$NEW_CA_SHA" == "$EXPECTED_CA_SHA" ]] ||
    fail_remote "Primljeni CA nije serverov aktualni CA"

openssl verify \
    -CAfile "$CA" \
    -verify_ip "$EXPECTED_IP" \
    "$CERT" >/dev/null 2>&1 ||
    fail_remote "NIDS certifikat ne vrijedi za $EXPECTED_IP"

cmp -s \
    <(openssl pkey -in "$KEY" -pubout 2>/dev/null) \
    <(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null) ||
    fail_remote "NIDS certifikat ne odgovara privatnom kljucu"

echo "[PASS] nids TLS enrollment i verifikacija"

REMOTE_NIDS

    pass "nids"
}


echo "=========================================="
echo " TLS SETUP / ENROLLMENT"
echo "=========================================="

for cmd in openssl ssh ssh-keygen ssh-copy-id ss sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail "Nedostaje naredba na serveru: $cmd"
done

for file in \
    "$BASE/config.sh" \
    "$BASE/server.conf" \
    "$BASE/dozvoljeni_agenti.txt" \
    "$BASE/tls-ca.sh" \
    "$BASE/tls-ca-listener.sh"; do

    [[ -f "$file" ]] ||
        fail "Nedostaje datoteka: $file"
done


source "$BASE/config.sh"
init_config "$BASE"

CA_CERT="$BASE/ca/ca-cert.pem"

SERVER_KEY="$BASE/ssl/server-key.pem"
SERVER_CSR="$BASE/ssl/server.csr"
SERVER_CERT="$BASE/ssl/server-cert.pem"
SERVER_CA="$BASE/ssl/ca-cert.pem"

ISSUED_SERVER_CERT="$BASE/ca/issued/server-cert.pem"


bootstrap_ssh

prepare_server_identity

CA_SHA="$(sha256sum "$CA_CERT" | awk '{print $1}')"

info "Aktualni CA SHA256=$CA_SHA"

start_ca_listener


for node in agent-01 agent-02 agent-03; do
    setup_agent "$node"
done

setup_nids


echo
echo "=========================================="
echo " TLS SETUP: PASS"
echo "=========================================="
