#!/usr/bin/env bash
# E2：链路质量渐变与提前避险（已合并原 E3A）。
# 故障对象：LB-R3-R5（10.16.6.0/29），只在 R3->R5 单向施加 tc netem，
# 业务流：H1->H3（172.16.3.10，主分析流）。
# 四阶段渐变（对齐计划书表9）：正常20s / 轻度10ms+1% / 中度30ms+3% / 重度50ms+5%，各20s，恢复观察5s。
# 方案无关：自动读取 state/current_scheme（E2 只跑 S2/S5/S6），用前先 ./scripts/run.sh scheme <name>。
set -Eeuo pipefail
trap 'rc=$?; echo "[e2][error] line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh

[[ -f state/interfaces.env ]] || {
  echo '缺少 state/interfaces.env，请先运行 ./scripts/run.sh addresses' >&2; exit 1
}
source state/interfaces.env

# 只在 R3 出方向单向损伤（计划书：单向，每加25ms RTT约增25ms）
LOCAL_IF=${R3__r3_r5:?缺少 R3__r3_r5 接口映射}
TARGET=172.16.3.10          # H3
SCHEME="${SCHEME:-$(cat state/current_scheme 2>/dev/null || echo s2)}"

STAGE_SECS=${E2_STAGE_SECS:-20}   # 每个阶段时长
TAIL_SECS=${E2_TAIL_SECS:-15}     # 恢复后观察（S6 danger回落约需13s，拉长以抓到回切）时长
TOTAL_SECS=$((STAGE_SECS * 4 + TAIL_SECS))
PING_COUNT=$((TOTAL_SECS * 5))    # ping -i 0.2 -> 每秒5包

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${E2_OUTPUT:-results/e2/${SCHEME}-${STAMP}}"
mkdir -p "$OUT"

compose_exec() { "${COMPOSE[@]}" exec -T --interactive=false "$@"; }
event() { printf '%s,%s,%s\n' "$(date +%s%3N)" "$1" "$2" >> "$OUT/events.csv"; }
clear_damage() {
  compose_exec R3 tc qdisc del dev "$LOCAL_IF" root >/dev/null 2>&1 || true
}
trap clear_damage EXIT

printf 'timestamp_ms,event,details\n' > "$OUT/events.csv"
date -Is > "$OUT/run-start.txt"
{
  echo "scheme=$SCHEME"
  echo "damage_link=LB-R3-R5 (R3:$LOCAL_IF -> R5), one-way R3->R5 only"
  echo "business=H1->H3 ($TARGET)"
  echo "stage_seconds=$STAGE_SECS tail_seconds=$TAIL_SECS total_seconds=$TOTAL_SECS"
  echo "stage_normal=0ms/0%"
  echo "stage_mild=10ms/1%"
  echo "stage_moderate=30ms/3%"
  echo "stage_severe=50ms/5%"
  echo "ping_count=$PING_COUNT interval=0.2s"
} > "$OUT/parameters.txt"

apply_stage() {  # $1=delay(空=清除) $2=loss
  local delay=$1 loss=$2
  if [[ -z "$delay" ]]; then
    compose_exec R3 tc qdisc del dev "$LOCAL_IF" root >/dev/null 2>&1 || true
  else
    compose_exec R3 tc qdisc replace dev "$LOCAL_IF" root netem delay "$delay" loss "$loss"
  fi
}

# ---------- 实验前快照（先清理可能残留的 tc，保证从干净状态起步） ----------
clear_damage
compose_exec R3 vtysh -c 'show ip route 172.16.3.0/24' > "$OUT/route-before.txt" 2>&1 || true
compose_exec R3 tc -s qdisc show dev "$LOCAL_IF" > "$OUT/qdisc-before.txt" 2>&1 || true

echo "[e2] scheme=$SCHEME output=$OUT"
echo "[e2] damage R3:$LOCAL_IF one-way; H1->H3; 4 stages x ${STAGE_SECS}s + ${TAIL_SECS}s tail"

# ---------- 等待 R3 主路径下一跳就绪（避开 RIB 未装完、误走管理网的启动抖动） ----------
for i in $(seq 1 15); do
  nh=$(compose_exec R3 ip route get "$TARGET" 2>/dev/null | grep -oE 'via [0-9.]+' | head -n1 | awk '{print $2}' || true)
  [[ "$nh" == 10.16.* ]] && { echo "[e2] R3 primary next-hop=$nh ready after ${i}s"; break; }
  sleep 1
done

# ---------- 启动全程 ping ----------
compose_exec H1 ping -D -i 0.2 -c "$PING_COUNT" -W 1 "$TARGET" > "$OUT/H1-H3-ping.txt" 2>&1 &
PING_PID=$!

# ---------- 后台每2s采样 R3 到 H3 的实际下一跳（捕捉切换时刻） ----------
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

# ---------- 四阶段渐变 ----------
event stage_normal "0ms 0% duration=${STAGE_SECS}s"
sleep "$STAGE_SECS"

apply_stage 10ms 1%
event stage_mild "delay=10ms loss=1% duration=${STAGE_SECS}s"
sleep "$STAGE_SECS"

apply_stage 30ms 3%
event stage_moderate "delay=30ms loss=3% duration=${STAGE_SECS}s"
sleep "$STAGE_SECS"

apply_stage 50ms 5%
event stage_severe "delay=50ms loss=5% duration=${STAGE_SECS}s"
sleep "$STAGE_SECS"

apply_stage "" ""
event stage_recover "damage cleared, tail=${TAIL_SECS}s"
sleep "$TAIL_SECS"

# ---------- 收尾 ----------
kill "$WATCH_PID" 2>/dev/null || true
wait "$PING_PID" || true
clear_damage

compose_exec R3 vtysh -c 'show ip route 172.16.3.0/24' > "$OUT/route-after.txt" 2>&1 || true
compose_exec R3 tc -s qdisc show dev "$LOCAL_IF" > "$OUT/qdisc-after.txt" 2>&1 || true
date -Is > "$OUT/run-end.txt"
# S5/S6：保存控制器日志（含风险分级与 Cost 更新时间点）
if [[ "$SCHEME" == 's5' || "$SCHEME" == 's6' ]]; then
  [[ -f state/controller.log ]] && cp state/controller.log "$OUT/controller.log"
  [[ -f state/controller.pid ]] && cp state/controller.pid "$OUT/controller.pid"
fi
{
  echo "output=$OUT"
  echo "scheme=$SCHEME"
  echo "damage_link=LB-R3-R5 one-way R3->R5"
  echo "business=H1->H3"
  echo "stages=normal/mild/moderate/severe/recover"
  echo "ping_file=H1-H3-ping.txt"
  echo "events=events.csv"
  echo "route_watch=route_watch.csv (R3 next-hop every 2s)"
  echo "note=E2 gradual degradation (merged E3A); warning/danger/cost timing in controller.log for S5/S6"
} > "$OUT/summary.txt"

echo "E2 ($SCHEME) finished; results: $OUT"
