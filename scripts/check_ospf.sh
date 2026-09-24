#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"; source scripts/common.sh
failed=0
for n in $(seq 1 12); do
  echo "=== R$n ==="
  out=$("${COMPOSE[@]}" exec -T --interactive=false "R$n" vtysh -c 'show ip ospf neighbor' || true)
  printf '%s\n' "$out"
  grep -q 'Full' <<< "$out" || failed=1
done
exit "$failed"
