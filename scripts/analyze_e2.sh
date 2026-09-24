#!/usr/bin/env bash
# 分析 E2 结果：对 results/e2/ 下每个方案目录（或指定目录）输出分阶段丢包、
# RTT、R3 下一跳切换、控制器状态/Cost 更新汇总。
# 用法：./scripts/analyze_e2.sh [results/e2/s2-xxxx]
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [[ $# -ge 1 ]]; then
  DIRS=("$@")
else
  mapfile -t DIRS < <(find results/e2 -mindepth 1 -maxdepth 1 -type d | sort)
fi

for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  scheme=$(grep -E '^scheme=' "$d/summary.txt" 2>/dev/null | cut -d= -f2 || basename "$d")
  echo "################################################################"
  echo "# E2 方案=$scheme  目录=$d"
  echo "################################################################"

  pingf="$d/H1-H3-ping.txt"
  if [[ -f "$pingf" ]]; then
    echo "-- 总体 --"
    grep -E 'packets transmitted|rtt min' "$pingf" || echo "(无统计行)"
    echo "-- 分阶段（按 icmp_seq，每100包=20s：正常/轻度/中度/重度/恢复）--"
    tail_s=$(grep -oE 'tail_seconds=[0-9]+' "$d/parameters.txt" 2>/dev/null | head -1 | cut -d= -f2)
    rec_exp=$(( ${tail_s:-15} * 5 ))
    awk -v rec="$rec_exp" '
      {
        seq=-1; rtt=-1
        if (match($0,/icmp_seq=[0-9]+/)) seq=substr($0,RSTART+9,RLENGTH-9)+0
        if (match($0,/time=[0-9.]+/))   rtt=substr($0,RSTART+5,RLENGTH-5)+0
        if (seq>0) {
          st=int((seq-1)/100)+1; if(st>5)st=5
          recv[st]++; if(rtt>=0){sum[st]+=rtt; if(rtt>mx[st])mx[st]=rtt}
        }
      }
      END{
        name[1]="正常  ";name[2]="轻度  ";name[3]="中度  ";name[4]="重度  ";name[5]="恢复  "
        expect[1]=100;expect[2]=100;expect[3]=100;expect[4]=100;expect[5]=rec
        for(i=1;i<=5;i++){
          r=recv[i]+0; l=expect[i]-r; avg=(r>0?sum[i]/r:0)
          printf "  %s 收到%3d/%d 丢%3d  平均RTT%7.2fms 最大%7.2fms\n",name[i],r,expect[i],l,avg,mx[i]
        }
      }' "$pingf"
  fi

  rw="$d/route_watch.csv"
  if [[ -f "$rw" ]]; then
    echo "-- R3 到 H3 下一跳变化（采样间隔2s；10.16.6.3=走R5主路径, 10.16.5.3=走R4备用）--"
    awk -F, 'NR>1{
      nh="?"
      if(match($2,/via [0-9.]+/)) nh=substr($2,RSTART+4,RLENGTH-4)
      if(nh!=prev){ printf "  采样行%-3d (~%3ds)  下一跳=%s\n", NR-1, (NR-2)*2, nh; prev=nh }
    }' "$rw"
  fi

  cl="$d/controller.log"
  if [[ -f "$cl" ]]; then
    echo "-- 控制器事件 --"
    echo "  状态切换次数: $(grep -c ' STATE ' "$cl" || true)"
    grep ' STATE ' "$cl" | sed 's/^/    /' || true
    echo "  Cost 更新次数: $(grep -c 'COST UPDATED' "$cl" || true)"
    grep 'COST UPDATED' "$cl" | sed 's/^/    /' || true
  fi
  echo
done
