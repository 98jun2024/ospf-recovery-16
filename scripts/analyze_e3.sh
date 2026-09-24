#!/usr/bin/env bash
# 分析 E3 结果：故障检测、控制面收敛、业务恢复/中断时长。
# 时间轴统一以 events.csv 的 fault_on 时刻为 0s（负值=故障前）。
# 注意：只把真正的 echo reply（"bytes from <目标>"）计为收到；
#       "From x icmp_seq=.. Destination Host Unreachable" 是 ICMP error，不算恢复。
# 用法：./scripts/analyze_e3.sh [results/e3/s2-xxxx ...]
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TARGET=172.16.3.10

if [[ $# -ge 1 ]]; then DIRS=("$@"); else
  mapfile -t DIRS < <(find results/e3 -mindepth 1 -maxdepth 1 -type d | sort); fi

for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  scheme=$(grep -E '^scheme=' "$d/summary.txt" 2>/dev/null | cut -d= -f2 || basename "$d")
  fault_at=$(grep -E 'fault_on_at=' "$d/parameters.txt" 2>/dev/null | cut -d= -f2 | sed 's/s.*//' || echo 60)
  # fault_on 的毫秒时间戳（watch/ping 都对齐到它）
  fault_ms=$(awk -F, '$2=="fault_on"{print $1; exit}' "$d/events.csv" 2>/dev/null || true)
  echo "################################################################"
  echo "# E3 方案=$scheme  目录=$d  (故障注入于 ${fault_at}s)"
  echo "################################################################"

  pingf="$d/H1-H3-ping.txt"
  if [[ -f "$pingf" ]]; then
    echo "-- 总体 --"
    grep -E 'packets transmitted|rtt min' "$pingf" || echo "(无统计行)"
    echo "-- 业务中断分析（只计真实回显 bytes from ${TARGET}；ICMP Unreachable 不算恢复）--"
    awk -v fat="$fault_at" -v tgt="$TARGET" '
      {
        if (index($0,"bytes from " tgt)>0 && match($0,/icmp_seq=[0-9]+/)) {
          s=substr($0,RSTART+9,RLENGTH-9)+0; recv[s]=1; if(s>max)max=s; got++
        } else if ($0 ~ /[Uu]nreachable/ && match($0,/icmp_seq=[0-9]+/)) { icmperr++ }
      }
      END{
        start=int(fat*5)+1
        firstloss=0; resume=0
        for(s=start;s<=max;s++){ if(!(s in recv)){ firstloss=s; break } }
        if(firstloss){ for(s=firstloss;s<=max;s++){ if(s in recv){ resume=s; break } } }
        printf "  真实回显=%d  ICMP不可达=%d\n", got+0, icmperr+0
        if(firstloss==0){ print "  故障后无丢包（业务未中断）" }
        else {
          lt=(firstloss-1)*0.2
          if(resume){ rt=(resume-1)*0.2
            printf "  首个丢包 seq=%d (故障%+.1fs)\n  首个真实回显 seq=%d (故障%+.1fs)\n  业务中断时长≈%.1fs\n",firstloss,lt-fat,resume,rt-fat,rt-lt
          } else { printf "  首个丢包 seq=%d (故障%+.1fs)，之后无真实回显\n",firstloss,lt-fat }
        }
      }' "$pingf"
  fi

  nw="$d/neighbor_watch.csv"
  if [[ -f "$nw" ]]; then
    echo "-- R3 看到的 R5 邻居（相对故障秒；Full/MISSING/重建other）--"
    awk -F, -v fms="$fault_ms" 'NR==2{ if(fms=="")t0=$1; else t0=fms } NR>1{
      st=($2 ~ /FULL|Full/ ?"Full": ($2 ~ /MISSING/?"MISSING":"other"))
      if(st!=prev){ printf "  故障%+4ds  %s\n",($1-t0)/1000, st; prev=st }
    }' "$nw"
  fi

  rw="$d/route_watch.csv"
  if [[ -f "$rw" ]]; then
    echo "-- R3 到 H3 下一跳（相对故障秒；10.16.6.3=主R5, 10.16.5.3=备R4）--"
    awk -F, -v fms="$fault_ms" 'NR==2{ if(fms=="")t0=$1; else t0=fms } NR>1{
      nh="?"; if(match($2,/via [0-9.]+/)) nh=substr($2,RSTART+4,RLENGTH-4)
      if(nh!=prev){ printf "  故障%+4ds  下一跳=%s\n",($1-t0)/1000,nh; prev=nh }
    }' "$rw"
  fi

  for extra in qdisc-faulton-r3.txt qdisc-faulton-r5.txt ospf-if-faulton.txt bfd-peers-faulton.txt; do
    if [[ -f "$d/$extra" ]]; then
      echo "-- $extra --"
      sed 's/^/  /' "$d/$extra" | head -n 25
    fi
  done

  cl="$d/controller.log"
  if [[ -f "$cl" ]]; then
    echo "-- 控制器事件 --"
    grep -E ' STATE |COST UPDATED' "$cl" | sed 's/^/  /' || true
  fi
  echo
done
