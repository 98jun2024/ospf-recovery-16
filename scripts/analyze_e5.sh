#!/usr/bin/env bash
# 分析 E5：总体 + 三阶段(正常/扰动/恢复)丢包与 P95、正常段误报、下一跳切换次数、
# 控制器风险等级变化 / danger 次数 / Cost 更新次数、随机扰动事件清单。
# 用法：./scripts/analyze_e5.sh [results/e5/s5-xxxx ...]（不带参数则分析 results/e5 全部目录）
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [[ $# -ge 1 ]]; then DIRS=("$@"); else mapfile -t DIRS < <(find results/e5 -mindepth 1 -maxdepth 1 -type d | sort); fi

# 抽取某 seq 区间 [lo,hi] 的 RTT 列表（busybox ping 兼容：icmp_seq= / time=）
seg_rtt() {  # $1=pingfile $2=lo $3=hi
  awk -v lo="$2" -v hi="$3" '{
    s=-1; r=-1
    if (match($0,/icmp_seq=[0-9]+/)) s=substr($0,RSTART+9,RLENGTH-9)+0
    if (match($0,/time=[0-9.]+/))    r=substr($0,RSTART+5,RLENGTH-5)+0
    if (s>=lo && s<=hi && r>=0) print r
  }' "$1"
}
# 从 RTT 列表算 P95（升序后取 ceil(0.95n)）
p95() { sort -n | awk '{a[NR]=$1} END{ if(NR==0){print "0.00"}else{ i=int(NR*0.95+0.999999); if(i<1)i=1; if(i>NR)i=NR; printf "%.2f", a[i] } }'; }

for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  scheme=$(grep -E '^scheme=' "$d/summary.txt" 2>/dev/null | cut -d= -f2 || basename "$d")
  n=$(grep -oE 'normal_seconds=[0-9]+' "$d/parameters.txt" 2>/dev/null | head -1 | cut -d= -f2); n=${n:-20}
  c=$(grep -oE 'churn_seconds=[0-9]+'  "$d/parameters.txt" 2>/dev/null | head -1 | cut -d= -f2); c=${c:-60}
  t=$(grep -oE 'tail_seconds=[0-9]+'  "$d/parameters.txt" 2>/dev/null | head -1 | cut -d= -f2); t=${t:-20}
  n1=1; n2=$((n*5)); c1=$((n2+1)); c2=$(((n+c)*5)); t1=$((c2+1)); t2=$(((n+c+t)*5))

  echo "################################################################"
  echo "# E5 方案=$scheme  目录=$d  (正常${n}s/扰动${c}s/恢复${t}s)"
  echo "################################################################"

  pf="$d/H1-H3-ping.txt"
  if [[ -f "$pf" ]]; then
    echo "-- 总体 --"
    grep -E 'packets transmitted|rtt min' "$pf" || echo '(无统计行)'
    echo "  全程 P95 RTT = $(seg_rtt "$pf" 1 999999 | p95) ms"

    echo "-- 分阶段（收/期望、丢、平均、最大、P95）--"
    for seg in "正常:$n1:$n2" "扰动:$c1:$c2" "恢复:$t1:$t2"; do
      nm=${seg%%:*}; rg=${seg#*:}; lo=${rg%:*}; hi=${rg#*:}; exp=$((hi-lo+1))
      vals=$(seg_rtt "$pf" "$lo" "$hi")
      stat=$(echo "$vals" | awk -v nm="$nm" -v want="$exp" '
        {sum+=$1; if($1>mx)mx=$1; n++}
        END{ n=n+0; printf "  %s 收%3d/%d 丢%3d 平均%7.2fms 最大%7.2fms", nm, n, want, want-n, (n?sum/n:0), mx+0 }')
      echo "$stat   P95=$(echo "$vals" | p95)ms"
    done

    got=$(seg_rtt "$pf" "$n1" "$n2" | wc -l); base_loss=$((n2-n1+1-got))
    if [[ $base_loss -eq 0 ]]; then echo "  正常段误报检查：0 丢包 [OK]"; else echo "  正常段误报检查：丢 ${base_loss} 包（基线不应丢，留意环境抖动）"; fi
  fi

  rw="$d/route_watch.csv"
  if [[ -f "$rw" ]]; then
    echo "-- R3->H3 下一跳（10.16.6.3=主/R5，10.16.5.3=备/R4；扰动 r4_r7/r5_r7 时不应切）--"
    sw=$(awk -F, 'NR>1{ if(match($2,/via [0-9.]+/))nh=substr($2,RSTART+4,RLENGTH-4); if(NR>2 && nh!=prev)k++; prev=nh } END{print k+0}' "$rw")
    echo "  下一跳切换次数: $sw"
    awk -F, 'NR>1{ if(match($2,/via [0-9.]+/))nh=substr($2,RSTART+4,RLENGTH-4); if(nh!=prev){printf "  采样行%-3d(~%3ds) 下一跳=%s\n",NR-1,(NR-2)*2,nh; prev=nh} }' "$rw"
  fi

  cl="$d/controller.log"
  if [[ -f "$cl" ]]; then
    echo "-- 控制器事件 --"
    echo "  风险等级(STATE)变化次数: $(grep -c ' STATE ' "$cl" || true)"
    echo "  进入 danger 次数: $(grep -cE 'STATE [a-z]+ -> danger' "$cl" || true)"
    echo "  Cost 更新次数: $(grep -c 'COST UPDATED' "$cl" || true)"
    grep ' STATE ' "$cl" | sed 's/^/    /' || true
    echo "  末次 r3_r5 状态: $(grep 'r3_r5 q=' "$cl" | tail -1 | grep -oE 'state=[a-z]+' || echo NA)"
    echo "  末次 Cost: $(grep 'COST UPDATED' "$cl" | tail -1 | grep -oE '\-> [0-9]+' || echo NA)"
  fi

  ev="$d/events.csv"
  if [[ -f "$ev" ]]; then
    echo "-- 随机扰动事件（对照：扰动 r4_r7/r5_r7 的时隙主路径不应切换）--"
    grep ',disturb,' "$ev" | sed 's/^/  /' || true
  fi
  echo
done
