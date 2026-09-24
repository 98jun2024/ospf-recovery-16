#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
"${COMPOSE[@]}" ps
for n in $(seq 1 12); do
  printf 'R%-2s ' "$n"
  "${COMPOSE[@]}" exec -T --interactive=false "R$n" ip -br addr 2>/dev/null | tr '\n' ' '
  echo
done
