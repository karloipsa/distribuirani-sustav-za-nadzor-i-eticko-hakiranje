#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="/etc/hosts"
BEGIN_MARKER="# BEGIN DIPLOMSKI-HOSTS"
END_MARKER="# END DIPLOMSKI-HOSTS"

PROJECT_ENTRIES=(
  "192.168.100.1 server"
  "192.168.100.2 agent-01"
  "192.168.100.3 agent-02"
  "192.168.100.4 agent-03"
  "192.168.100.254 nids"
)

PROJECT_NAMES=(server agent-01 agent-02 agent-03 nids)

if (( EUID != 0 )); then
  echo "FAIL: pokreni skriptu kao root, npr. sudo ./setup-hosts.sh" >&2
  exit 1
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "FAIL: $HOSTS_FILE ne postoji" >&2
  exit 1
fi

backup="${HOSTS_FILE}.diplomski.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$HOSTS_FILE" "$backup"
echo "Backup: $backup"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

awk '
  BEGIN { in_managed_block = 0 }

  $0 == "# BEGIN DIPLOMSKI-HOSTS" {
    in_managed_block = 1
    next
  }

  $0 == "# END DIPLOMSKI-HOSTS" {
    in_managed_block = 0
    next
  }

  in_managed_block {
    next
  }

  {
    remove_line = 0

    for (i = 2; i <= NF; i++) {
      if ($i == "server" ||
          $i == "agent-01" ||
          $i == "agent-02" ||
          $i == "agent-03" ||
          $i == "nids") {
        remove_line = 1
        break
      }
    }

    if (!remove_line) {
      print
    }
  }
' "$HOSTS_FILE" > "$tmp"

{
  printf '\n%s\n' "$BEGIN_MARKER"
  printf '%s\n' "${PROJECT_ENTRIES[@]}"
  printf '%s\n' "$END_MARKER"
} >> "$tmp"

install -o root -g root -m 0644 "$tmp" "$HOSTS_FILE"

echo "Provjera hostname zapisa:"

fail=0
for entry in "${PROJECT_ENTRIES[@]}"; do
  ip="${entry%% *}"
  name="${entry#* }"

  if getent hosts "$name" | awk '{print $1}' | grep -Fxq "$ip"; then
    echo "PASS: $name -> $ip"
  else
    echo "FAIL: $name se ne razrješava na $ip" >&2
    fail=1
  fi
done

if (( fail != 0 )); then
  echo "FAIL: /etc/hosts je ažuriran, ali provjera nije prošla" >&2
  exit 1
fi

echo "PASS: projektni /etc/hosts zapisi su spremni"