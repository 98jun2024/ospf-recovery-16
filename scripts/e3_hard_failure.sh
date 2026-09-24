#!/usr/bin/env bash
# E3：固定主路径硬故障恢复（无软恶化基线，单链路断开再恢复）。
# 故障对象：LB-R3-R5，两端同时 tc netem loss 100%（接口保持 up、报文全丢），
#   —— 用 loss 100% 而非 ip link down，才能体现 S2(Dead40s)/S3(Dead3s)/S4(BFD150ms) 的检测差异。
# 时间线（计划书：60s 断、80s 恢复）：正常 BASE_SECS -> 故障 DOWN_SECS -> 恢复观察 RECOVER_SECS。
# 业务流：H1->H3（172.16.3.10）。方案无关，自动读 state/current_scheme（E3 跑 S2/S3/S4/S6）。
set -Eeuo pipefail
trap 'rc=$?; echo "[e3][error] line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh

[[ -f state/interfaces.env ]] || {
  echo '缺少 state/interfaces.env，请先运行 ./scripts/run.sh addresses' >&2; exit 1
}
source state/interfaces.env

R3_IF=${R3__r3_r5:?缺少 R3__r3_r5 接口映射}
R5_IF=${R5__r3_r5:?缺少 R5__r3_r5 接口映射}
TARGET=172.16.3.10          # H3
R5_RID=10.255.0.5           # R5 Router-ID，用于邻居状态观察
SCHEME="${SCHEME:-$(cat state/current_scheme 2>/dev/null || echo s2)}"

BASE_SECS=${E3_BASE_SECS:-60}       # 故障前稳定基线
DOWN_SECS=${E3_DOWN_SECS:-20}       # 故障持续（60s断，80s恢复）
RECOVER_SECS=${E3_RECOVER_SECS:-30} # 恢复后观察
TOTAL_SECS=$((BASE_SECS + DOWN_SECS + RECOVER_SECS))
PING_COUNT=$((TOTAL_SECS * 5))      # ping -i 0.2

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${E3_OUTPUT:-results/e3/${SCHEME}-${STAMP}}"
mkdir -p "$OUT"

compose_exec() { "${COMPOSE[@]}" exec -T --interactive=false "$@"; }
event() { printf '%s,%s,%s\n' "$(date +%s%3N)" "$1" "$2" >> "$OUT/events.csv"; }
clear_fault() {
  compose_exec R3 tc qdisc del dev "$R3_IF" root >/dev/null 2>&1 || true
  compose_exec R5 tc qdisc del dev "$R5_IF" root >/dev/null 2>&1 || true
}
trap clear_fault EXIT

printf 'timestamp_ms,event,details\n' > "$OUT/events.csv"
date -Is > "$OUT/run-start.txt"
{
  echo "scheme=$SCHEME"
  echo "fault_link=LB-R3-R5 (R3:$R3_IF, R5:$R5_IF), bidirectional loss 100%"
  echo "business=H1->H3 ($TARGET)"
  echo "base_seconds=$BASE_SECS down_seconds=$DOWN_SECS recover_seconds=$RECOVER_SECS total=$TOTAL_SECS"
  echo "fault_on_at=${BASE_SECS}s fault_off_at=$((BASE_SECS+DOWN_SECS))s"
  echo "ping_count=$PING_COUNT interval=0.2s"
} > "$OUT/parameters.txt"

inject_fault() {  # $1=on|off
  if [[ "$1" == on ]]; then
    compose_exec R3 tc qdisc replace dev "$R3_IF" root netem loss 100%
    compose_exec R5 tc qdisc replace dev "$R5_IF" root netem loss 100%
  else
    clear_fault
  fi
}

# ---------- 实验前快照 + 清理残留 ----------
clear_fault
compose_exec R3 vtysh -c 'show ip route 172.16.3.0/24' > "$OUT/route-before.txt" 2>&1 || true
compose_exec R3 vtysh -c 'show ip ospf neighbor' > "$OUT/neighbor-before.txt" 2>&1 || true
compose_exec R3 tc -s qdisc show dev "$R3_IF" > "$OUT/qdisc-before-r3.txt" 2>&1 || true
compose_exec R5 tc -s qdisc show dev "$R5_IF" > "$OUT/qdisc-before-r5.txt" 2>&1 || true

echo "[e3] scheme=$SCHEME output=$OUT"
echo "[e3] R3-R5 bidirectional loss100%; base=${BASE_SECS}s down=${DOWN_SECS}s recover=${RECOVER_SECS}s"

# ---------- 等待 R3 主路径下一跳就绪（避开 RIB 未装完的启动抖动） ----------
for i in $(seq 1 15); do
  nh=$(compose_exec R3 ip route get "$TARGET" 2>/dev/null | grep -oE 'via [0-9.]+' | head -n1 | awk '{print $2}' || true)
  [[ "$nh" == 10.16.* ]] && { echo "[e3] R3 primary next-hop=$nh ready after ${i}s"; break; }
  sleep 1
done

# ---------- 全程 ping（带时间戳，用于精确算中断/恢复时刻） ----------
compose_exec H1 ping -D -i 0.2 -c "$PING_COUNT" -W 1 "$TARGET" > "$OUT/H1-H3-ping.txt" 2>&1 &
PING_PID=$!

# ---------- 后台每1s采样 R3 到 H3 下一跳 ----------
printf 'timestamp_ms,r3_route_get_to_H3\n' > "$OUT/route_watch.csv"
(
  while true; do
    {
      printf '%s,' "$(date +%s%3N)"
      compose_exec R3 ip route get "$TARGET" 2>/dev/null | head -n1 | tr -d '\n' || true
      printf '\n'
    } >> "$OUT/route_watch.csv"
    sleep 1
  done
) &
ROUTE_WATCH_PID=$!

# ---------- 后台每1s采样 R3 看到的 R5 OSPF 邻居状态 ----------
printf 'timestamp_ms,r5_neighbor_line\n' > "$OUT/neighbor_watch.csv"
(
  while true; do
    line=$(compose_exec R3 vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep "$R5_RID" | tr -d '\n' || true)
    [[ -z "$line" ]] && line='R5_NEIGHBOR_MISSING'
    printf '%s,%s\n' "$(date +%s%3N)" "$line" >> "$OUT/neighbor_watch.csv"
    sleep 1
  done
) &
NB_WATCH_PID=$!

# ---------- 时间线 ----------
event stage_baseline "0-${BASE_SECS}s stable"
sleep "$BASE_SECS"

inject_fault on
event fault_on "R3-R5 bidirectional loss 100% at ${BASE_SECS}s"
echo "[e3] fault ON at ${BASE_SECS}s"
# 故障进行3s后采样诊断：确认tc真在丢、接口定时器实际值、BFD peer是否UP
sleep 3
compose_exec R3 tc -s qdisc show dev "$R3_IF" > "$OUT/qdisc-faulton-r3.txt" 2>&1 || true
compose_exec R5 tc -s qdisc show dev "$R5_IF" > "$OUT/qdisc-faulton-r5.txt" 2>&1 || true
compose_exec R3 vtysh -c "show ip ospf interface $R3_IF" > "$OUT/ospf-if-faulton.txt" 2>&1 || true
compose_exec R3 vtysh -c 'show bfd peers' > "$OUT/bfd-peers-faulton.txt" 2>&1 || true
sleep $((DOWN_SECS - 3))

inject_fault off
event fault_off "R3-R5 restored at $((BASE_SECS+DOWN_SECS))s"
echo "[e3] fault OFF, observing recovery ${RECOVER_SECS}s"
sleep "$RECOVER_SECS"

# ---------- 收尾 ----------
kill "$ROUTE_WATCH_PID" "$NB_WATCH_PID" 2>/dev/null || true
wait "$PING_PID" || true
clear_fault

compose_exec R3 vtysh -c 'show ip route 172.16.3.0/24' > "$OUT/route-after.txt" 2>&1 || true
compose_exec R3 vtysh -c 'show ip ospf neighbor' > "$OUT/neighbor-after.txt" 2>&1 || true
date -Is > "$OUT/run-end.txt"
if [[ "$SCHEME" == 's5' || "$SCHEME" == 's6' ]]; then
  [[ -f state/controller.log ]] && cp state/controller.log "$OUT/controller.log"
  [[ -f state/controller.pid ]] && cp state/controller.pid "$OUT/controller.pid"
fi
{
  echo "output=$OUT"
  echo "scheme=$SCHEME"
  echo "fault_link=LB-R3-R5 bidirectional loss100"
  echo "business=H1->H3"
  echo "timeline=base${BASE_SECS}s/down${DOWN_SECS}s/recover${RECOVER_SECS}s"
  echo "ping_file=H1-H3-ping.txt (-D timestamped)"
  echo "events=events.csv"
  echo "route_watch=route_watch.csv (R3 next-hop every 1s)"
  echo "neighbor_watch=neighbor_watch.csv (R3 view of R5 adjacency every 1s)"
  echo "metrics=detection/control-convergence/service-recovery/outage duration, derived from events+ping+watches"
} > "$OUT/summary.txt"

echo "E3 ($SCHEME) finished; results: $OUT"
