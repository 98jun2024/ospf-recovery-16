#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh
python3 scripts/generate_configs.py
source state/interfaces.env
[[ $(wc -l < state/interfaces.env) -eq 46 ]] || { echo 'state/interfaces.env 不完整，请先运行 ./scripts/run.sh addresses' >&2; exit 1; }
for n in $(seq 1 12); do
  rid="10.255.0.$n"
  "${COMPOSE[@]}" exec -T --interactive=false "R$n" vtysh -c 'conf t' -c 'router ospf' -c "router-id $rid" -c 'network 10.16.0.0/16 area 0' -c 'network 172.16.0.0/16 area 0' -c 'passive-interface default' -c 'maximum-paths 1' -c end >/dev/null
done
for row in "${LINK_ROWS[@]}"; do
  IFS='|' read -r name subnet ra ipa rb ipb cost <<< "$row"
  key=${name//-/_}
  for endpoint in "$ra:$ipa" "$rb:$ipb"; do
    router=${endpoint%%:*}; var="${router}__${key}"; iface=${!var}
    "${COMPOSE[@]}" exec -T --interactive=false "$router" vtysh -c 'conf t' -c 'router ospf' -c "no passive-interface $iface" -c exit -c "interface $iface" -c 'ip ospf network point-to-point' -c "ip ospf cost $cost" -c end >/dev/null
  done
done
for n in $(seq 1 12); do "${COMPOSE[@]}" exec -T --interactive=false "R$n" vtysh -c 'write memory' >/dev/null; done
echo 'OSPF configured'
