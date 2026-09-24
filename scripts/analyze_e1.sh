#!/usr/bin/env bash
# 分析 E1 基线结果：业务 ping 连通性、12 台路由器 OSPF 邻居 Full 情况、
# 关键业务路由是否学到、S5/S6 控制器在健康链路上是否保持 Q≈0 且无误更新。
# 用法：./scripts/analyze_e1.sh [results/e1/s2-xxxx ...]
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [[ $# -ge 1 ]]; then DIRS=("$@"); else
  mapfile -t DIRS < <(find results/e1 -mindepth 1 -maxdepth 1 -type d | sort); fi

# 每台路由器的期望 OSPF 邻居数（由19条链路的度决定）
declare -A EXPECT=( [R1]=2 [R2]=3 [R3]=3 [R4]=5 [R5]=3 [R6]=3 [R7]=4 [R8]=4 [R9]=3 [R10]=4 [R11]=2 [R12]=2 )

for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  scheme=$(grep -E '^scheme=' "$d/summary.txt" 2>/dev/null | cut -d= -f2 || basename "$d")
  echo "################################################################"
  echo "# E1 方案=$scheme  目录=$d"
  echo "################################################################"

  echo "-- 业务 ping（基线应 0% 丢包）--"
  for pf in H1-H3-ping-100.txt H2-H4-ping-100.txt; do
    if [[ -f "$d/$pf" ]]; then
      printf '  [%s]\n' "$pf"
      grep -E 'packets transmitted|rtt min|round-trip' "$d/$pf" | sed 's/^/    /' || true
    fi
  done

  echo "-- OSPF 邻居（实际Full数/期望数；非Full会标出）--"
  bad=0
  for n in $(seq 1 12); do
    node="R$n"; nf="$d/neighbors/$node.txt"
    [[ -f "$nf" ]] || { echo "  $node: 缺少邻居文件"; bad=1; continue; }
    full=$(grep -c -E 'Full' "$nf" || true)
    exp=${EXPECT[$node]}
    nonfull=$(grep -E 'Init|Loading|Exchange|ExStart|2-Way|Attempt|Down' "$nf" || true)
    if [[ "$full" -eq "$exp" && -z "$nonfull" ]]; then
      printf '  %s: %d/%d Full  OK\n' "$node" "$full" "$exp"
    else
      printf '  %s: %d/%d Full  !! 异常\n' "$node" "$full" "$exp"
      [[ -n "$nonfull" ]] && echo "$nonfull" | sed 's/^/      /'
      bad=1
    fi
  done
  [[ $bad -eq 0 ]] && echo "  => 12 台路由器邻居全部 Full" || echo "  => 存在邻居异常，请查看上面 !! 行"

  echo "-- 关键业务路由（R1 应学到对端 H3/H4 两个 LAN）--"
  r1="$d/routes/R1.txt"
  if [[ -f "$r1" ]]; then
    for lan in 172.16.3.0 172.16.4.0; do
      if grep -q "$lan" "$r1"; then echo "  R1 -> $lan/24 已学到 OK"; else echo "  R1 -> $lan/24 未学到 !!"; fi
    done
  fi

  cl="$d/controller.log"
  if [[ -f "$cl" ]]; then
    echo "-- 控制器健康（基线下健康链路 Q 应接近0、不应有状态切换/误更新）--"
    nstate=$(grep -c ' STATE ' "$cl" || true)
    nupd=$(grep -c 'COST UPDATED' "$cl" || true)
    # 稳态Q：剔除控制器启动前6s warmup 的冷启动样本（避免启动瞬间ping未就绪造成Q=1尖峰）
    maxq=$(awk '
      match($0,/\[[0-9]+\]/){ts=substr($0,RSTART+1,RLENGTH-2)+0; if(t0=="")t0=ts}
      match($0,/q=[0-9.]+/){v=substr($0,RSTART+2,RLENGTH-2)+0; if(ts-t0>=6000 && v>m)m=v}
      END{ if(m=="") print "N/A"; else printf "%.3f\n", m }' "$cl" || true)
    echo "  状态切换次数=$nstate  Cost更新次数=$nupd  稳态最大Q(剔除启动6s)=${maxq:-N/A}"
    if [[ "$nupd" -gt 0 ]]; then
      echo "  基线出现 Cost 更新（健康链路不应更新），明细："
      grep 'COST UPDATED' "$cl" | sed 's/^/    /' || true
    fi
    grep -E 'SAMPLE_FAIL|PARSE_ANOMALY' "$cl" | sed 's/^/  /' || true
  fi
  echo
done
