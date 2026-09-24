#!/usr/bin/env bash
# 分析 E4 节点故障（docker stop/start R5）结果：
#   受损流 H1->H3 的业务中断时长；对照流 H2->H4 在故障窗口是否无损；
#   R3 看 R5 邻接 Full->MISSING->Full 的时间线；两方向下一跳变化。
# 时间轴以 events.csv 的 node_stop 时刻为 0s（负值=故障前）。
# 只把真正的 echo reply（"bytes from <目标>"）计为收到；ICMP Unreachable 不算恢复。
# 用法：./scripts/analyze_e4.sh [results/e4/s2-xxxx ...]
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TARGET_A=172.16.3.10
TARGET_B=172.16.4.10

if [[ $# -ge 1 ]]; then DIRS=("$@"); else
  mapfile -t DIRS < <(find results/e4 -mindepth 1 -maxdepth 1 -type d | sort); fi

# 受损流中断分析：首个丢包 -> 首个真实回显 = 业务中断时长
outage_awk='
  {
    if (index($0,"bytes from " tgt)>0 && match($0,/icmp_seq=[0-9]+/)) {
      s=substr($0,RSTART+9,RLENGTH-9)+0; recv[s]=1; if(s>max)max=s; got++
    } else if ($0 ~ /[Uu]nreachable/ && match($0,/icmp_seq=[0-9]+/)) { icmperr++ }
  }
  END{
    start=int(fat*5)+1; firstloss=0; resume=0
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
  }'

for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  scheme=$(grep -E '^scheme=' "$d/summary.txt" 2>/dev/null | cut -d= -f2 || basename "$d")
  stop_at=$(grep -oE 'node_stop_at=[0-9]+' "$d/parameters.txt" 2>/dev/null | head -n1 | cut -d= -f2); stop_at=${stop_at:-60}
  down=$(grep -oE 'down_seconds=[0-9]+' "$d/parameters.txt" 2>/dev/null | head -n1 | cut -d= -f2); down=${down:-20}
  stop_ms=$(awk -F, '$2=="node_stop"{print $1; exit}' "$d/events.csv" 2>/dev/null || true)
  echo "################################################################"
  echo "# E4 方案=$scheme  目录=$d  (R5 停机于 ${stop_at}s，停 ${down}s)"
  echo "################################################################"

  pa="$d/H1-H3-ping.txt"
  if [[ -f "$pa" ]]; then
    echo "-- 受损流 H1->H3（经过 R5）总体 --"
    grep -E 'packets transmitted|rtt min' "$pa" || echo "(无统计行)"
    echo "-- 受损流业务中断分析（只计 bytes from ${TARGET_A}，Unreachable 不算）--"
    awk -v fat="$stop_at" -v tgt="$TARGET_A" "$outage_awk" "$pa"
  fi

  pb="$d/H2-H4-ping.txt"
  if [[ -f "$pb" ]]; then
    echo "-- 对照流 H2->H4（不经过 R5，应全程无损）总体 --"
    grep -E 'packets transmitted|rtt min' "$pb" || echo "(无统计行)"
    awk -v fat="$stop_at" -v down="$down" -v tgt="$TARGET_B" '
      { if (index($0,"bytes from " tgt)>0 && match($0,/icmp_seq=[0-9]+/)) {
          s=substr($0,RSTART+9,RLENGTH-9)+0; recv[s]=1; got++
        } else if ($0 ~ /[Uu]nreachable/) { icmperr++ } }
      END{ lo=int(fat*5)+1; hi=int((fat+down)*5); miss=0
        for(s=lo;s<=hi;s++) if(!(s in recv)) miss++
        printf "  故障窗口(seq %d-%d)真实回显=%d/%d 丢=%d（期望 0 丢，验证故障隔离）\n",lo,hi,(hi-lo+1-miss),(hi-lo+1),miss
      }' "$pb"
  fi

  w="$d/watch.csv"
  if [[ -f "$w" ]]; then
    echo "-- 下一跳 / R3看R5邻接 变化时间线（相对 R5 停机秒）--"
    awk -F, -v fms="$stop_ms" 'NR==2{ t0=(fms==""?$1:fms) } NR>1{
      if($2!=pa){ printf "  故障%+5ds  R3->H3 下一跳 = %s\n",($1-t0)/1000,$2; pa=$2 }
      if($3!=pb){ printf "  故障%+5ds  R2->H4 下一跳 = %s  (对照流,应恒定)\n",($1-t0)/1000,$3; pb=$3 }
      if($4!=pc){ printf "  故障%+5ds  R3看R5邻接 = %s\n",($1-t0)/1000,$4; pc=$4 }
    }' "$w"
  fi

  for extra in node-stopped-ps.txt neigh-faulton-R3.txt neigh-faulton-R7.txt neigh-faulton-R9.txt bfd-peers-faulton.txt route-faulton-A.txt route-faulton-B.txt; do
    if [[ -f "$d/$extra" ]]; then
      echo "-- $extra --"
      sed 's/^/  /' "$d/$extra" | head -n 20
    fi
  done

  cl="$d/controller.log"
  if [[ -f "$cl" ]]; then
    echo "-- 控制器事件 --"
    grep -E ' STATE |COST UPDATED' "$cl" | sed 's/^/  /' || true
  fi
  echo
done
