#!/usr/bin/env bash
set -euo pipefail

# Cleanup mora imati root ovlasti zbog:
# - iptables / ip6tables / nft
# - gašenja procesa drugih korisnika
# - fuser/lsof operacija
if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

BASE="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$BASE/log"

say() {
    echo -e "$@"
}

# --------------------------------------------------
# Gašenje glavnih procesa
# --------------------------------------------------

say "---- Zaustavljam procese sustava (+ djeca) ----"

kill_tree_by_name() {
    local name="$1"
    local pids
    local pid

    pids=$(
        ps -eo pid,command |
        awk -v n="$name" '
        BEGIN { IGNORECASE=0 }
        ($0 ~ "(^|[[:space:]])(bash[[:space:]]+)?(\\./|/).*" n "([[:space:]]|$)") {
            print $1
        }'
    )

    [[ -z "${pids:-}" ]] && return 0

    say "Gašim: $name  PID(s): $pids"

    # Prvo djeca procesa.
    for pid in $pids; do
        pkill -TERM -P "$pid" 2>/dev/null || true
    done

    sleep 0.3

    # Zatim glavni procesi.
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 0.5

    # Ako je nešto tvrdoglavo ostalo.
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
}

kill_tree_by_name "agent.sh"
kill_tree_by_name "server.sh"
kill_tree_by_name "nids.sh"
kill_tree_by_name "control.sh"

# --------------------------------------------------
# Gašenje pomoćnih alata
# --------------------------------------------------

say "---- Gašenje pomoćnih alata ----"

pkill -f nmap        2>/dev/null || true
pkill -f tcpdump     2>/dev/null || true

pkill -f "ncat .*--listen" 2>/dev/null || true
pkill -f "ncat .* -l"      2>/dev/null || true

# Eksperimentalni generatori prometa.
pkill -x nping       2>/dev/null || true
pkill -x ping        2>/dev/null || true

# --------------------------------------------------
# Zatvaranje portova
# --------------------------------------------------

say "---- Zatvaram portove sustava ----"

close_port() {
    local port="$1"

    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${port}/tcp" 2>/dev/null || true
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -nPtiTCP:"$port" -sTCP:LISTEN |
        xargs -r kill -9 2>/dev/null || true
    fi
}

# Server sluša na 5000.
if [[ -f "$BASE/server.sh" ]]; then
    close_port 5000
fi

# NIDS control sluša na 5001.
if [[ -f "$BASE/nids.sh" || -f "$BASE/control.sh" ]]; then
    close_port 5001
fi

# Agenti slušaju peer komunikaciju na 6000.
if [[ -f "$BASE/agent.sh" ]]; then
    close_port 6000
fi

# --------------------------------------------------
# Provjera oslobađanja portova
# --------------------------------------------------

wait_port_free() {
    local port="$1"

    for _ in {1..30}; do
        if ! ss -lntp 2>/dev/null |
             awk '{print $4}' |
             grep -Eq "(:|\])${port}$"; then
            return 0
        fi

        sleep 0.2
    done

    return 1
}

if [[ -f "$BASE/server.sh" ]]; then
    wait_port_free 5000 ||
        say "UPOZORENJE: port 5000 i dalje zauzet"
fi

if [[ -f "$BASE/nids.sh" || -f "$BASE/control.sh" ]]; then
    wait_port_free 5001 ||
        say "UPOZORENJE: port 5001 i dalje zauzet"
fi

if [[ -f "$BASE/agent.sh" ]]; then
    wait_port_free 6000 ||
        say "UPOZORENJE: port 6000 i dalje zauzet"
fi

# --------------------------------------------------
# Čišćenje iptables IPv4 pravila
# --------------------------------------------------

say "---- Čišćenje IPv4 firewall pravila ----"

if command -v iptables >/dev/null 2>&1; then

    # Server / agent pravila:
    # INPUT + nadzor-mreze
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        delete_line="${line/-A /-D }"
        iptables $delete_line 2>/dev/null || true

    done < <(
        iptables -S INPUT 2>/dev/null |
        grep 'nadzor-mreze' || true
    )

    # NIDS pravila:
    # FORWARD + diplomski-nids
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        delete_line="${line/-A /-D }"
        iptables $delete_line 2>/dev/null || true

    done < <(
        iptables -S FORWARD 2>/dev/null |
        grep 'diplomski-nids' || true
    )
fi

# --------------------------------------------------
# Čišćenje ip6tables IPv6 pravila
# --------------------------------------------------

say "---- Čišćenje IPv6 firewall pravila ----"

if command -v ip6tables >/dev/null 2>&1; then

    # Server / agent pravila:
    # INPUT + nadzor-mreze
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        delete_line="${line/-A /-D }"
        ip6tables $delete_line 2>/dev/null || true

    done < <(
        ip6tables -S INPUT 2>/dev/null |
        grep 'nadzor-mreze' || true
    )

    # Eventualna NIDS IPv6 pravila:
    # FORWARD + diplomski-nids
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        delete_line="${line/-A /-D }"
        ip6tables $delete_line 2>/dev/null || true

    done < <(
        ip6tables -S FORWARD 2>/dev/null |
        grep 'diplomski-nids' || true
    )
fi

# --------------------------------------------------
# Čišćenje eventualnih direktnih nft pravila
# --------------------------------------------------

say "---- Čišćenje nft pravila sustava ----"

if command -v nft >/dev/null 2>&1; then

    while IFS='|' read -r family table chain handle; do

        [[ -z "${family:-}" ]] && continue
        [[ -z "${table:-}" ]]  && continue
        [[ -z "${chain:-}" ]]  && continue
        [[ -z "${handle:-}" ]] && continue

        nft delete rule \
            "$family" \
            "$table" \
            "$chain" \
            handle "$handle" \
            2>/dev/null || true

    done < <(
        nft -a list ruleset 2>/dev/null |
        awk '
        /^table / {
            family=$2
            table=$3
        }

        /^[[:space:]]*chain / {
            chain=$2
        }

        /(nadzor-mreze|diplomski-nids)/ && /# handle [0-9]+/ {
            for (i=1; i<=NF; i++) {
                if ($i == "handle") {
                    print family "|" table "|" chain "|" $(i+1)
                    break
                }
            }
        }'
    )
fi

# --------------------------------------------------
# Reset logova i privremenih datoteka
# --------------------------------------------------

say "---- Reset logova i privremenih datoteka ----"

mkdir -p "$LOG_DIR"

# Brišemo samo logove koji pripadaju komponenti
# na kojoj je clean.sh trenutno pokrenut.

if [[ -f "$BASE/agent.sh" ]]; then
    : > "$LOG_DIR/agent.log"
    : > "$LOG_DIR/listener.err"

    rm -f \
        "$LOG_DIR/banner_cache.txt" \
        "$LOG_DIR"/cap_*.pcap \
        2>/dev/null || true
fi

if [[ -f "$BASE/server.sh" ]]; then
    : > "$LOG_DIR/promet.log"
    : > "$LOG_DIR/ncat_listener.err"
fi

if [[ -f "$BASE/nids.sh" ]]; then
    : > "$LOG_DIR/nids.log"
fi

# Privremene datoteke eksperimentalnih PowerShell skripti.
rm -f \
    /tmp/exp05-* \
    /tmp/exp06-* \
    /tmp/exp07-* \
    /tmp/diplomski-exp05-* \
    /tmp/diplomski-exp06-* \
    /tmp/diplomski-exp07-* \
    2>/dev/null || true

# --------------------------------------------------
# Završna provjera procesa
# --------------------------------------------------

say "---- Provjera nakon čišćenja ----"

check_process_gone() {
    local name="$1"

    if pgrep -af "$name" >/dev/null 2>&1; then
        say "UPOZORENJE: $name proces još postoji:"
        pgrep -af "$name" || true
    else
        say "Nema više $name procesa"
    fi
}

check_process_gone "agent.sh"
check_process_gone "server.sh"
check_process_gone "nids.sh"
check_process_gone "control.sh"

# --------------------------------------------------
# Završna provjera IPv4 firewall pravila
# --------------------------------------------------

if command -v iptables >/dev/null 2>&1; then

    remaining_v4="$(
        {
            iptables -S INPUT 2>/dev/null |
                grep 'nadzor-mreze' || true

            iptables -S FORWARD 2>/dev/null |
                grep 'diplomski-nids' || true
        }
    )"

    if [[ -n "$remaining_v4" ]]; then
        say "UPOZORENJE: ostala su naša IPv4 pravila:"
        echo "$remaining_v4"
    else
        say "IPv4: nema naših pravila"
    fi
fi

# --------------------------------------------------
# Završna provjera IPv6 firewall pravila
# --------------------------------------------------

if command -v ip6tables >/dev/null 2>&1; then

    remaining_v6="$(
        {
            ip6tables -S INPUT 2>/dev/null |
                grep 'nadzor-mreze' || true

            ip6tables -S FORWARD 2>/dev/null |
                grep 'diplomski-nids' || true
        }
    )"

    if [[ -n "$remaining_v6" ]]; then
        say "UPOZORENJE: ostala su naša IPv6 pravila:"
        echo "$remaining_v6"
    else
        say "IPv6: nema naših pravila"
    fi
fi

# --------------------------------------------------
# Završna provjera nft pravila
# --------------------------------------------------

if command -v nft >/dev/null 2>&1; then

    remaining_nft="$(
        nft -a list ruleset 2>/dev/null |
        grep -E 'nadzor-mreze|diplomski-nids' || true
    )"

    if [[ -n "$remaining_nft" ]]; then
        say "UPOZORENJE: ostala su naša nft pravila:"
        echo "$remaining_nft"
    else
        say "nft: nema naših pravila"
    fi
fi

say "---- Gotovo ----"
