#!/usr/bin/env bash
# E5：随机扰动下的稳定性 / 抗抖动（误报、误切、Cost 抖动、P95、丢包）。
# 思路：固定随机种子，在 CHURN 段内以 3-12s 的随机时隙，对【控制器能感知的受控链路】
#       r3_r5(主路径,R3端) / r4_r7(备用侧,R4端) / r5_r7(备用侧,R5端) 随机切换扰动档位，
#       模拟全网随机质量波动。业务主路径 H1->H3 只经过 r3_r5；扰动 r4_r7/r5_r7 时业务本不该
#       被切走，正好检验 S5/S6 会不会误报 danger / 误切备用。只跑 S2/S5/S6。
# 时序：正常 NORMAL 20s（误报基线）/ 随机扰动 CHURN 60s / 恢复 TAIL 20s，共 100s=500 包(-i0.2)。
# 队列档：tbf 限 10M + 20M UDP 背景流，仅当 H1/H3 都有 iperf3 时启用；否则自动只用 netem 档，保证一定能跑。
# 方案无关：自动读 state/current_scheme，用前先 ./scripts/run.sh scheme <s2|s5|s6>。
set -Eeuo pipefail
trap 'rc=$?; echo "[e5][error] line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh

[[ -f state/interfaces.env ]] || {
  echo '缺少 state/interfaces.env，请先运行 ./scripts/run.sh addresses' >&2; exit 1
}
source state/interfaces.env

IF_R3R5=${R3__r3_r5:?缺少 R3__r3_r5 接口映射}
IF_R4R7=${R4__r4_r7:?缺少 R4__r4_r7 接口映射}
IF_R5R7=${R5__r5_r7:?缺少 R5__r5_r7 接口映射}
TARGET=172.16.3.10          # H3
SCHEME="${SCHEME:-$(cat state/current_scheme 2>/dev/null || echo s2)}"
SEED="${E5_SEED:-20260908}" # 固定随机种子，保证可复现
NORMAL_SECS="${E5_NORMAL_SECS:-20}"
CHURN_SECS="${E5_CHURN_SECS:-60}"
TAIL_SECS="${E5_TAIL_SECS:-20}"
TOTAL_SECS=$((NORMAL_SECS + CHURN_SECS + TAIL_SECS))
PING_COUNT=$((TOTAL_SECS * 5))   # -i 0.2 -> 每秒5包

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${E5_OUTPUT:-results/e5/${SCHEME}-${STAMP}}"
mkdir -p "$OUT"

compose_exec() { "${COMPOSE[@]}" exec -T --interactive=false "$@"; }
event() { printf '%s,%s,%s\n' "$(date +%s%3N)" "$1" "$2" >> "$OUT/events.csv"; }

clear_all() {
  compose_exec R3 tc qdisc del dev "$IF_R3R5" root >/dev/null 2>&1 || true
  compose_exec R4 tc qdisc del dev "$IF_R4R7" root >/dev/null 2>&1 || true
  compose_exec R5 tc qdisc del dev "$IF_R5R7" root >/dev/null 2>&1 || true
}
stop_udp() {
  compose_exec H1 pkill iperf3 >/dev/null 2>&1 || true
  compose_exec H3 pkill iperf3 >/dev/null 2>&1 || true
}
cleanup() { clear_all; stop_udp; }
trap cleanup EXIT

# 在指定路由器出接口施加一个扰动档位：none|mild|moderate|severe|queue
apply_profile() {  # $1=router $2=iface $3=profile
  local r=$1 ifc=$2 prof=$3
  case "$prof" in
    none)     compose_exec "$r" tc qdisc del dev "$ifc" root >/dev/null 2>&1 || true ;;
    mild)     compose_exec "$r" tc qdisc replace dev "$ifc" root netem delay 10ms loss 1% ;;
    moderate) compose_exec "$r" tc qdisc replace dev "$ifc" root netem delay 30ms loss 3% ;;
    severe)   compose_exec "$r" tc qdisc replace dev "$ifc" root netem delay 50ms loss 5% ;;
    queue)    compose_exec "$r" tc qdisc replace dev "$ifc" root tbf rate 10mbit burst 32kbit latency 400ms ;;
    *)        echo "[e5] unknown profile $prof" >&2; return 1 ;;
  esac
}

# iperf3 可用性探测：队列档 + UDP 背景流依赖它，缺了就自动降级为纯 netem
UDP_OK=0
if compose_exec H3 sh -c 'command -v iperf3' >/dev/null 2>&1 \
   && compose_exec H1 sh -c 'command -v iperf3' >/dev/null 2>&1; then
  UDP_OK=1
fi
PROFILES=(none mild moderate severe)
[[ $UDP_OK -eq 1 ]] && PROFILES+=(queue)
LINKS=(r3_r5 r4_r7 r5_r7)

printf 'timestamp_ms,event,details\n' > "$OUT/events.csv"
date -Is > "$OUT/run-start.txt"
{
  echo "scheme=$SCHEME"
  echo "seed=$SEED (fixed bash RANDOM, reproducible)"
  echo "disturb_links=r3_r5@R3(main path), r4_r7@R4, r5_r7@R5 (all in controller KEY_LINKS)"
  echo "business=H1->H3 ($TARGET); only r3_r5 is on main path, disturbing other two tests false-switch"
  echo "normal_seconds=$NORMAL_SECS churn_seconds=$CHURN_SECS tail_seconds=$TAIL_SECS total_seconds=$TOTAL_SECS"
  echo "slot_seconds=random 3..12"
  echo "profiles=none/mild(10ms,1%)/moderate(30ms,3%)/severe(50ms,5%)/queue(tbf10m+20M UDP if iperf3)"
  echo "udp_queue_available=$UDP_OK"
  echo "ping_count=$PING_COUNT interval=0.2s"
} > "$OUT/parameters.txt"

clear_all
stop_udp
echo "[e5] scheme=$SCHEME seed=$SEED output=$OUT udp_queue=$UDP_OK"
echo "[e5] NORMAL ${NORMAL_SECS}s / CHURN ${CHURN_SECS}s (slot 3-12s random) / TAIL ${TAIL_SECS}s"

# 等 R3 主下一跳就绪，避开启动期误走管理网
for i in $(seq 1 15); do
  nh=$(compose_exec R3 ip route get "$TARGET" 2>/dev/null | grep -oE 'via [0-9.]+' | head -n1 | awk '{print $2}' || true)
  [[ "$nh" == 10.16.* ]] && { echo "[e5] R3 primary next-hop=$nh ready after ${i}s"; break; }
  sleep 1
done

# 全程业务 ping
compose_exec H1 ping -D -i 0.2 -c "$PING_COUNT" -W 1 "$TARGET" > "$OUT/H1-H3-ping.txt" 2>&1 &
PING_PID=$!

# 下一跳 watch（每2s）
printf 'timestamp_ms,r3_route_get_to_H3\n' > "$OUT/route_watch.csv"
(
  while true; do
    {
      printf '%s,' "$(date +%s%3N)"
      compose_exec R3 ip route get "$TARGET" 2>/dev/null | head -n1 | tr -d '\n' || true
      printf '\n'
    } >> "$OUT/route_watch.csv"
    sleep 2
  done
) &
WATCH_PID=$!

# ---- NORMAL 基线（期望：0 danger、0 切换、≈0 丢包）----
event normal "baseline ${NORMAL_SECS}s (expect no danger/no switch/~0 loss)"
sleep "$NORMAL_SECS"

# ---- 队列档需要的 UDP 背景流（只在 CHURN 段打）----
if [[ $UDP_OK -eq 1 ]]; then
  compose_exec H3 iperf3 -s -D >/dev/null 2>&1 || true
  compose_exec H1 iperf3 -u -c "$TARGET" -b 20M -t "$CHURN_SECS" > "$OUT/udp-iperf.txt" 2>&1 &
fi

# ---- CHURN 随机扰动（固定种子可复现）----
RANDOM=$SEED
event churn_start "random disturbance ${CHURN_SECS}s"
churn_begin=$(date +%s)
slot_idx=0
while :; do
  elapsed=$(( $(date +%s) - churn_begin ))
  [[ $elapsed -ge $CHURN_SECS ]] && break
  slot=$(( RANDOM % 10 + 3 ))                 # 3..12s
  remain=$(( CHURN_SECS - elapsed ))
  [[ $slot -gt $remain ]] && slot=$remain     # 最后一个时隙不越界
  [[ $slot -lt 1 ]] && break
  link=${LINKS[$((RANDOM % ${#LINKS[@]}))]}
  prof=${PROFILES[$((RANDOM % ${#PROFILES[@]}))]}
  slot_idx=$((slot_idx + 1))
  clear_all                                  # 每轮先清，保证同一时刻只有一条链路被扰动（单一变量）
  case "$link" in
    r3_r5) apply_profile R3 "$IF_R3R5" "$prof" ;;
    r4_r7) apply_profile R4 "$IF_R4R7" "$prof" ;;
    r5_r7) apply_profile R5 "$IF_R5R7" "$prof" ;;
  esac
  event disturb "slot#$slot_idx link=$link profile=$prof duration=${slot}s"
  sleep "$slot"
done
clear_all
event churn_end "all disturbance cleared"

# ---- TAIL 恢复观察（期望：回主路径、state 回 normal、Cost 回落）----
sleep "$TAIL_SECS"

kill "$WATCH_PID" 2>/dev/null || true
wait "$PING_PID" || true
clear_all
stop_udp

# S5/S6 保存控制器日志
if [[ "$SCHEME" == 's5' || "$SCHEME" == 's6' ]]; then
  [[ -f state/controller.log ]] && cp state/controller.log "$OUT/controller.log"
  [[ -f state/controller.pid ]] && cp state/controller.pid "$OUT/controller.pid"
fi
date -Is > "$OUT/run-end.txt"
{
  echo "output=$OUT"
  echo "scheme=$SCHEME"
  echo "seed=$SEED"
  echo "business=H1->H3"
  echo "slot_count=$slot_idx"
  echo "ping_file=H1-H3-ping.txt"
  echo "events=events.csv"
  echo "route_watch=route_watch.csv (R3 next-hop every 2s)"
  echo "metrics=loss/P95, next-hop switches, STATE changes, COST updates, false-switch on non-main-path disturbance"
} > "$OUT/summary.txt"

echo "E5 ($SCHEME) finished; slots=$slot_idx results: $OUT"
