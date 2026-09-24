#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "[e1][error] line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh

SCHEME="${SCHEME:-$(cat state/current_scheme 2>/dev/null || echo s2)}"
STAMP=$(date +%Y%m%d-%H%M%S) #时间戳
OUT="${E1_OUTPUT:-results/e1/${SCHEME}-${STAMP}}"
mkdir -p "$OUT/neighbors" "$OUT/routes" "$OUT/interfaces"

exec 3>&1
echo "[e1] scheme=$SCHEME output=$OUT"
date -Is > "$OUT/run-start.txt"
"${COMPOSE[@]}" ps > "$OUT/compose-ps.txt"
"${COMPOSE[@]}" config > "$OUT/compose-config.txt"

echo '[e1] collecting container interface snapshots'
for node in R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 H1 H2 H3 H4; do
  "${COMPOSE[@]}" exec -T --interactive=false "$node" ip -o -4 addr show > "$OUT/interfaces/$node.txt"
done

echo '[e1] collecting OSPF neighbors and routes'
for n in $(seq 1 12); do
  "${COMPOSE[@]}" exec -T --interactive=false "R$n" \
    vtysh -c 'show ip ospf neighbor' > "$OUT/neighbors/R$n.txt" 2>&1 || true
  "${COMPOSE[@]}" exec -T --interactive=false "R$n" \
    vtysh -c 'show ip route ospf' > "$OUT/routes/R$n.txt" 2>&1 || true
done

echo '[e1] running H1 -> H3 ping (100 packets)'
"${COMPOSE[@]}" exec -T --interactive=false H1 \
  ping -i 0.2 -c 100 -W 1 172.16.3.10 > "$OUT/H1-H3-ping-100.txt" 2>&1

echo '[e1] running H2 -> H4 ping (100 packets)'
"${COMPOSE[@]}" exec -T --interactive=false H2 \
  ping -i 0.2 -c 100 -W 1 172.16.4.10 > "$OUT/H2-H4-ping-100.txt" 2>&1

date -Is > "$OUT/run-end.txt"
# S5/S6：保存控制器日志与 PID，便于事后核查（其他方案无控制器，不复制残留日志）
if [[ "$SCHEME" == 's5' || "$SCHEME" == 's6' ]]; then
  [[ -f state/controller.log ]] && cp state/controller.log "$OUT/controller.log"
  [[ -f state/controller.pid ]] && cp state/controller.pid "$OUT/controller.pid"
fi
{
  echo "output=$OUT"
  echo "scheme=$SCHEME"
  echo "routers=12"
  echo "hosts=4"
  echo "link_count=19"
  echo "neighbor_files=12"
  echo "route_files=12"
  echo "ping_files=2"
  echo "note=E1 is a stable OSPF baseline; no impairment or failure was injected"
} > "$OUT/summary.txt"

echo "E1 baseline ($SCHEME) finished; results: $OUT"
