#!/usr/bin/env bash
# E4：节点级故障恢复——docker stop R5（其相邻 r3-r5 / r5-r7 / r5-r9 同时失效），再 docker start 恢复。
# 与 E3（单链路两端 tc loss100%、接口保持 up）互补：E4 模拟整台路由器宕机/重启，
#   R5 上 FRR 重启后需重新建立 3 个邻接、重泛洪 LSA、RIB 重新收敛。
# 两条业务流同时观测（方案无关，读 state/current_scheme；E4 跑 S2/S3/S4/S6）：
#   受损流 H1->H3(172.16.3.10)：H1-R1-R3-R5-R9-R11-H3，R5 在路径上，应先中断、绕备/随邻接重建而恢复；
#   对照流 H2->H4(172.16.4.10)：H2-R2-R4-R7-R10-R12-H4，不经过 R5，应全程连通（验证故障被隔离）。
# 方案在 apply_scheme 阶段已对每台 write memory，故 R5 start 后 FRR 会按保存配置自动重建邻接，无需重配。
set -Eeuo pipefail
trap 'rc=$?; echo "[e4][error] line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh

[[ -f state/interfaces.env ]] || {
  echo '缺少 state/interfaces.env，请先按序跑 up/discover/interface/configs/addresses' >&2; exit 1; }
source state/interfaces.env

FAILED_NODE=R5
FAILED_RID=10.255.0.5            # R5 Router-ID，用于在邻居表里定位它
SRC_A=H1; WATCH_A=R3; TARGET_A=172.16.3.10    # 受损流：在 R3 观测去 H3 的下一跳（主10.16.6.3/备10.16.5.3）
SRC_B=H2; WATCH_B=R2; TARGET_B=172.16.4.10    # 对照流：在 R2 观测去 H4 的下一跳（不经 R5，应稳定）
SCHEME="${SCHEME:-$(cat state/current_scheme 2>/dev/null || echo s2)}"

BASE_SECS=${E4_BASE_SECS:-60}        # 故障前稳定基线
DOWN_SECS=${E4_DOWN_SECS:-20}        # R5 停机时长
RECOVER_SECS=${E4_RECOVER_SECS:-45}  # R5 重启后观察（FRR 重建邻接+收敛，比 E3 撤销 tc 慢，给足）
TOTAL_SECS=$((BASE_SECS + DOWN_SECS + RECOVER_SECS))
PING_COUNT=$((TOTAL_SECS * 5))       # ping -i 0.2
WATCH_EVERY=${E4_WATCH_EVERY:-2}     # 合并采样周期（秒）；刻意 2s 以降低 exec 负载

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${E4_OUTPUT:-results/e4/${SCHEME}-${STAMP}}"
mkdir -p "$OUT"

compose_exec() { "${COMPOSE[@]}" exec -T --interactive=false "$@"; }
node_running() { local q; q=$("${COMPOSE[@]}" ps -q --status=running "$FAILED_NODE" 2>/dev/null || true); [[ -n "$q" ]]; }
event() { printf '%s,%s,%s\n' "$(date +%s%3N)" "$1" "$2" >> "$OUT/events.csv"; }
stop_node() { "${COMPOSE[@]}" stop -t 2 "$FAILED_NODE"; }    # -t 2：2s 后强停，避免默认等 10s 造成时刻漂移
start_node() { "${COMPOSE[@]}" start "$FAILED_NODE"; }
ensure_node_up() { node_running || { echo "[e4] ensuring $FAILED_NODE back up"; start_node >/dev/null 2>&1 || true; }; }
trap ensure_node_up EXIT     # 无论正常结束还是报错退出，都把 R5 拉回来，避免拓扑残留

next_hop() { compose_exec "$1" ip route get "$2" 2>/dev/null | grep -oE 'via [0-9.]+' | head -n1 | awk '{print $2}' || true; }

printf 'timestamp_ms,event,details\n' > "$OUT/events.csv"
date -Is > "$OUT/run-start.txt"
{
  echo "scheme=$SCHEME"
  echo "failed_node=$FAILED_NODE (docker stop/start); adjacent links r3-r5,r5-r7,r5-r9 all down while stopped"
  echo "flow_A=damaged: $SRC_A->H3 ($TARGET_A), watched at $WATCH_A (primary via R5 10.16.6.3 / backup via R4 10.16.5.3)"
  echo "flow_B=control: $SRC_B->H4 ($TARGET_B), watched at $WATCH_B (does NOT traverse R5, should stay reachable)"
  echo "base_seconds=$BASE_SECS down_seconds=$DOWN_SECS recover_seconds=$RECOVER_SECS total=$TOTAL_SECS"
  echo "node_stop_at=${BASE_SECS}s node_start_at=$((BASE_SECS+DOWN_SECS))s"
  echo "ping_count=$PING_COUNT interval=0.2s watch_every=${WATCH_EVERY}s"
} > "$OUT/parameters.txt"

# ---------- 实验前：保证 R5 在跑 + 快照 ----------
ensure_node_up
sleep 2
compose_exec "$WATCH_A" vtysh -c 'show ip route 172.16.3.0/24' > "$OUT/route-before-A.txt" 2>&1 || true
compose_exec "$WATCH_B" vtysh -c 'show ip route 172.16.4.0/24' > "$OUT/route-before-B.txt" 2>&1 || true
compose_exec R3 vtysh -c 'show ip ospf neighbor' > "$OUT/neighbor-before.txt" 2>&1 || true
"${COMPOSE[@]}" ps > "$OUT/ps-before.txt" 2>&1 || true

echo "[e4] scheme=$SCHEME output=$OUT"
echo "[e4] stop $FAILED_NODE base=${BASE_SECS}s down=${DOWN_SECS}s recover=${RECOVER_SECS}s; flows: $SRC_A->H3(damaged), $SRC_B->H4(control)"

# ---------- 就绪检查：两条流在观测点都学到 10.16 下一跳，避开启动抖动 ----------
ready=0
for i in $(seq 1 20); do
  na=$(next_hop "$WATCH_A" "$TARGET_A"); nb=$(next_hop "$WATCH_B" "$TARGET_B")
  if [[ "$na" == 10.16.* && "$nb" == 10.16.* ]]; then
    echo "[e4] both flows ready after ${i}s: $WATCH_A->H3 nh=$na, $WATCH_B->H4 nh=$nb"; ready=1; break
  fi
  sleep 1
done
[[ $ready -eq 1 ]] || echo '[e4][warn] 就绪检查未拿到两条流的 10.16 下一跳，仍继续，请检查 before 快照' >&2

# ---------- 两条业务流全程 ping（-D 带时间戳，用于精确算中断/恢复） ----------
compose_exec "$SRC_A" ping -D -i 0.2 -c "$PING_COUNT" -W 1 "$TARGET_A" > "$OUT/H1-H3-ping.txt" 2>&1 &
PA=$!
compose_exec "$SRC_B" ping -D -i 0.2 -c "$PING_COUNT" -W 1 "$TARGET_B" > "$OUT/H2-H4-ping.txt" 2>&1 &
PB=$!

# ---------- 单一合并采样循环（2s）：两方向下一跳 + R3 看到的 R5 邻居状态，尽量省 exec ----------
printf 'timestamp_ms,nh_to_H3_at_R3,nh_to_H4_at_R2,r5_adj_at_R3\n' > "$OUT/watch.csv"
(
  while true; do
    ra=$(next_hop R3 "$TARGET_A"); [[ -z "$ra" ]] && ra=NO_ROUTE
    rb=$(next_hop R2 "$TARGET_B"); [[ -z "$rb" ]] && rb=NO_ROUTE
    line=$(compose_exec R3 vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep "$FAILED_RID" || true)
    if   grep -q Full <<< "$line"; then ns=Full
    elif [[ -z "$line" ]]; then ns=MISSING
    else ns=other; fi
    printf '%s,%s,%s,%s\n' "$(date +%s%3N)" "$ra" "$rb" "$ns" >> "$OUT/watch.csv"
    sleep "$WATCH_EVERY"
  done
) &
WP=$!

# ---------- 时间线 ----------
event stage_baseline "0-${BASE_SECS}s stable"
sleep "$BASE_SECS"

stop_node
event node_stop "docker stop $FAILED_NODE at ${BASE_SECS}s"
echo "[e4] $FAILED_NODE STOPPED at ${BASE_SECS}s"
# 停机 3s 后抓现场：R3/R7/R9 三个原邻居的邻接状态、BFD、两方向路由、容器状态
sleep 3
"${COMPOSE[@]}" ps "$FAILED_NODE" > "$OUT/node-stopped-ps.txt" 2>&1 || true
for obs in R3 R7 R9; do
  compose_exec "$obs" vtysh -c 'show ip ospf neighbor' > "$OUT/neigh-faulton-$obs.txt" 2>&1 || true
done
compose_exec R3 vtysh -c 'show bfd peers' > "$OUT/bfd-peers-faulton.txt" 2>&1 || true
compose_exec R3 ip route get "$TARGET_A" > "$OUT/route-faulton-A.txt" 2>&1 || true
compose_exec R2 ip route get "$TARGET_B" > "$OUT/route-faulton-B.txt" 2>&1 || true
[[ $DOWN_SECS -gt 3 ]] && sleep $((DOWN_SECS - 3)) || true

start_node
event node_start "docker start $FAILED_NODE at $((BASE_SECS+DOWN_SECS))s, observe ${RECOVER_SECS}s"
echo "[e4] $FAILED_NODE STARTED, observing recovery ${RECOVER_SECS}s"
sleep "$RECOVER_SECS"

# ---------- 收尾 ----------
kill "$WP" 2>/dev/null || true
wait "$PA" "$PB" 2>/dev/null || true
ensure_node_up
compose_exec R3 vtysh -c 'show ip ospf neighbor' > "$OUT/neighbor-after.txt" 2>&1 || true
compose_exec R3 ip route get "$TARGET_A" > "$OUT/route-after-A.txt" 2>&1 || true
compose_exec R2 ip route get "$TARGET_B" > "$OUT/route-after-B.txt" 2>&1 || true
date -Is > "$OUT/run-end.txt"
if [[ "$SCHEME" == 's5' || "$SCHEME" == 's6' ]]; then
  [[ -f state/controller.log ]] && cp state/controller.log "$OUT/controller.log"
  [[ -f state/controller.pid ]] && cp state/controller.pid "$OUT/controller.pid"
fi
{
  echo "output=$OUT"
  echo "scheme=$SCHEME"
  echo "fault=docker stop/start $FAILED_NODE (node failure)"
  echo "flow_damaged=H1->H3 ($TARGET_A); flow_control=H2->H4 ($TARGET_B, should be unaffected)"
  echo "timeline=base${BASE_SECS}s/down${DOWN_SECS}s/recover${RECOVER_SECS}s"
  echo "ping_files=H1-H3-ping.txt,H2-H4-ping.txt (-D timestamped)"
  echo "events=events.csv; watch=watch.csv (nh of both flows + R3-view-of-R5 adjacency every ${WATCH_EVERY}s)"
  echo "metrics=damaged-flow outage duration; control-flow loss (expect ~0); adjacency Full->MISSING->Full timeline"
} > "$OUT/summary.txt"

echo "E4 ($SCHEME) finished; results: $OUT"
