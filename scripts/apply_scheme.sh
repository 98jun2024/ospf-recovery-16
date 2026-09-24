#!/usr/bin/env bash
# 方案部署层：在已启动的拓扑上切换 S2-S6 路由方案。
# 用法：./scripts/apply_scheme.sh <s2|s3|s4|s5|s6>
# 所有 E1-E5 场景脚本复用当前部署的方案，不在场景脚本里重复配置。
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh

SCHEME="${1:-}"
case "$SCHEME" in
  s2|s3|s4|s5|s6) ;;
  *) echo "usage: $0 <s2|s3|s4|s5|s6>" >&2; exit 2 ;;
esac

[[ -f state/interfaces.env ]] || {
  echo '缺少 state/interfaces.env，请先运行 ./scripts/run.sh addresses' >&2; exit 1
}
source state/interfaces.env
[[ $(wc -l < state/interfaces.env) -eq 46 ]] || {
  echo 'state/interfaces.env 不完整，请先运行 ./scripts/run.sh addresses' >&2; exit 1
}
echo "$SCHEME" > state/current_scheme

vtysh_exec() {
  "${COMPOSE[@]}" exec -T --interactive=false "$1" vtysh "${@:2}" >/dev/null 2>&1 || true
}

# ---------- 0. 停止旧的动态 Cost 控制器 ----------
if [[ -f state/controller.pid ]]; then
  oldpid=$(cat state/controller.pid 2>/dev/null || true)
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    kill "$oldpid" 2>/dev/null || true
    sleep 1
    kill -9 "$oldpid" 2>/dev/null || true
  fi
  rm -f state/controller.pid
fi
echo "[scheme] old controller stopped (if any)"

# ---------- 1. 基础 OSPF 进程配置（所有方案共有） ----------
echo "[scheme] applying base OSPF process (scheme=$SCHEME)"
for n in $(seq 1 12); do
  rid="10.255.0.$n"
  vtysh_exec "R$n" \
    -c 'conf t' -c 'router ospf' \
    -c "router-id $rid" \
    -c 'network 10.16.0.0/16 area 0' \
    -c 'network 172.16.0.0/16 area 0' \
    -c 'passive-interface default' \
    -c 'maximum-paths 1' \
    -c end
done

# ---------- 2a. 逐接口第一遍：清理旧增量 + 网络类型 + 固定Cost + 默认定时器 ----------
# 显式 set 回默认 10/40（等价 no，且更确定）；S4 在此使能接口 BFD。
echo "[scheme] applying per-interface base (p2p + cost + default timers)"
for row in "${LINK_ROWS[@]}"; do
  IFS='|' read -r name subnet ra ipa rb ipb cost <<< "$row"
  key=${name//-/_}
  for endpoint in "$ra:$ipa" "$rb:$ipb"; do
    router=${endpoint%%:*}; ip=${endpoint##*:}
    var="${router}__${key}"; iface=${!var}
    base_cmds=(-c 'conf t' -c "interface $iface"
      -c 'no ip ospf bfd'
      -c 'ip ospf network point-to-point' -c "ip ospf cost $cost"
      -c 'ip ospf hello-interval 10' -c 'ip ospf dead-interval 40')
    if [[ "$SCHEME" == 's4' ]]; then
      base_cmds+=(-c 'ip ospf bfd')
    fi
    base_cmds+=(-c end)
    vtysh_exec "$router" "${base_cmds[@]}"
  done
done

# ---------- 2b. S3 第二遍：基础稳定后独立下发快速定时器，并回读校验/重试 ----------
if [[ "$SCHEME" == 's3' ]]; then
  echo "[scheme] applying S3 fast timers (hello1/dead3) with verify"
  bad=0
  for row in "${LINK_ROWS[@]}"; do
    IFS='|' read -r name subnet ra ipa rb ipb cost <<< "$row"
    key=${name//-/_}
    for router in "$ra" "$rb"; do
      var="${router}__${key}"; iface=${!var}
      got=''
      for try in 1 2; do
        vtysh_exec "$router" -c 'conf t' -c "interface $iface" \
          -c 'ip ospf hello-interval 1' -c 'ip ospf dead-interval 3' -c end
        got=$("${COMPOSE[@]}" exec -T --interactive=false "$router" vtysh \
          -c "show ip ospf interface $iface" 2>/dev/null \
          | grep -oE 'Hello [0-9]+s, Dead [0-9]+s' | head -n1 || true)
        [[ "$got" == 'Hello 1s, Dead 3s' ]] && break
        sleep 1
      done
      if [[ "$got" != 'Hello 1s, Dead 3s' ]]; then
        echo "[scheme][warn] $router $iface fast-timer not applied (got: '$got')" >&2
        bad=$((bad + 1))
      fi
    done
  done
  if [[ $bad -eq 0 ]]; then echo '[scheme] S3 fast timers verified on ALL ospf interfaces';
  else echo "[scheme][warn] $bad interface(s) failed S3 timer verification" >&2; fi
fi

# ---------- 3. S4：全局 BFD peer（50ms × 3 次 = 150ms 检测） ----------
if [[ "$SCHEME" == 's4' ]]; then
  echo "[scheme] configuring BFD peers"
  # 收集每台路由器的所有对端 IP
  declare -A peers
  for row in "${LINK_ROWS[@]}"; do
    IFS='|' read -r name subnet ra ipa rb ipb cost <<< "$row"
    peers[$ra]="${peers[$ra]:-} $ipb"
    peers[$rb]="${peers[$rb]:-} $ipa"
  done
  for n in $(seq 1 12); do
    router="R$n"
    cmds=(-c 'conf t' -c 'bfd')
    for pip in ${peers[$router]:-}; do
      cmds+=(-c "peer $pip" -c 'tx-interval 50' -c 'rx-interval 50'
             -c 'detect-multiplier 3' -c 'no shutdown')
    done
    cmds+=(-c end)
    vtysh_exec "$router" "${cmds[@]}"
  done
fi

# ---------- 4. 保存配置 ----------
for n in $(seq 1 12); do
  vtysh_exec "R$n" -c 'write memory'
done

# ---------- 5. S5/S6：启动动态 Cost 控制器 ----------
if [[ "$SCHEME" == 's5' || "$SCHEME" == 's6' ]]; then
  echo "[scheme] starting dynamic cost controller (mode=$SCHEME)"
  nohup python3 scripts/dynamic_cost_controller.py --mode "$SCHEME" \
    > state/controller.log 2>&1 &
  echo $! > state/controller.pid
  sleep 2
  if ! kill -0 "$(cat state/controller.pid)" 2>/dev/null; then
    echo "[scheme][error] controller failed to start, see state/controller.log" >&2
    tail -n 20 state/controller.log >&2 || true
    exit 1
  fi
  echo "[scheme] controller pid=$(cat state/controller.pid)"
fi

# ---------- 6. 等待 OSPF 收敛 ----------
echo "[scheme] waiting for OSPF convergence (scheme=$SCHEME)..."
max_wait=90
elapsed=0
while [[ $elapsed -lt $max_wait ]]; do
  all_full=1
  for n in $(seq 1 12); do
    out=$("${COMPOSE[@]}" exec -T --interactive=false "R$n" vtysh -c 'show ip ospf neighbor' 2>/dev/null || true)
    if ! grep -q 'Full' <<< "$out"; then all_full=0; break; fi
  done
  if [[ $all_full -eq 1 ]]; then
    echo "[scheme] all 12 routers converged after ${elapsed}s"
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
if [[ $all_full -ne 1 ]]; then
  echo "[scheme][warn] not all neighbors Full after ${max_wait}s, check ./scripts/run.sh check" >&2
fi

echo "[scheme] $SCHEME deployed and ready"
