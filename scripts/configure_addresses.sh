#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "[addresses][error] line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh #加载此文件

ADDRESS_CMD_TIMEOUT=${ADDRESS_CMD_TIMEOUT:-20}
run_addr_cmd() {
  echo "[addresses] exec: $*"
  timeout "$ADDRESS_CMD_TIMEOUT" "${COMPOSE[@]}" exec -T --interactive=false "$@"
}

echo '[addresses] discovering Docker interfaces'
./scripts/discover_interfaces.sh
source state/interfaces.env
map_count=$(wc -l < state/interfaces.env)
[[ "$map_count" -eq 46 ]] || { echo "接口映射数量错误: $map_count/46" >&2; exit 1; }
echo '[addresses] applying router Loopback and link addresses'
for n in $(seq 1 12); do
  run_addr_cmd "R$n" ip addr replace "10.255.0.$n/32" dev lo
  run_addr_cmd "R$n" sysctl -w net.ipv4.ip_forward=1 >/dev/null
done
for row in "${LINK_ROWS[@]}"; do
  IFS='|' read -r name subnet ra ipa rb ipb cost <<< "$row"
  key=${name//-/_}; prefix=${subnet#*/}
  va="${ra}__${key}"; vb="${rb}__${key}"
  run_addr_cmd "$ra" ip addr replace "$ipa/$prefix" dev "${!va}"
  run_addr_cmd "$rb" ip addr replace "$ipb/$prefix" dev "${!vb}"
done
echo '[addresses] applying business LAN addresses'
for row in '1 R1 172.16.1.2 172.16.1.10' '2 R2 172.16.2.2 172.16.2.10' '3 R11 172.16.3.2 172.16.3.10' '4 R12 172.16.4.2 172.16.4.10'; do
  read -r n router rip hip <<< "$row"
  rvar="${router}__lan_h${n}"
  riface=${!rvar}
  run_addr_cmd "$router" ip addr replace "$rip/24" dev "$riface"
  hvar="H${n}__lan_h${n}"
  hiface=${!hvar}
  run_addr_cmd "H$n" ip addr replace "$hip/24" dev "$hiface"
  run_addr_cmd "H$n" ip route replace default via "$rip"
done
echo 'fixed addresses configured'
