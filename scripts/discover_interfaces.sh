#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; echo "[discover][error] line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source scripts/common.sh

DISCOVER_TIMEOUT=${DISCOVER_TIMEOUT:-15}
mkdir -p state #`-p` 是如果目录已存在也不报错
: > state/interfaces.env #清空并新建接口映射文件，保证每次运行都是全新的结果，不残留上一轮数据。

echo "[discover] version=local-ip-v3"

find_iface_by_local_ip() {
  local node="$1" local_ip="$2" output iface rc tmp

  echo "[discover]   lookup $node local-ip=$local_ip" >&2
  tmp=$(mktemp)
  if timeout "$DISCOVER_TIMEOUT" "${COMPOSE[@]}" exec -T --interactive=false "$node" ip -o -4 addr show >"$tmp" 2>&1; then
    :
  else
    rc=$?
    echo "[discover][error] cannot read IPv4 interfaces: node=$node exit=$rc" >&2
    cat "$tmp" >&2 || true
    rm -f "$tmp"
    return "$rc"
  fi

  iface=$(awk -v target="$local_ip" '
    {
      split($4, address, "/")
      if (address[1] == target) {
        name=$2
        sub(/@.*/, "", name)
        print name
        exit
      }
    }
  ' "$tmp")

  if [[ -z "$iface" || "$iface" == "lo" ]]; then
    echo "[discover][error] IP $local_ip was not found on $node" >&2
    cat "$tmp" >&2 || true
    rm -f "$tmp"
    return 1
  fi

  rm -f "$tmp"
  printf '%s\n' "$iface"
}

for row in "${LINK_ROWS[@]}"; do
  IFS='|' read -r link subnet a ip_a b ip_b cost <<< "$row"
  echo "[discover] $link: $a($ip_a) <-> $b($ip_b)"

  ia=$(find_iface_by_local_ip "$a" "$ip_a")
  echo "[discover]   found $a/$ip_a -> $ia"

  ib=$(find_iface_by_local_ip "$b" "$ip_b")
  echo "[discover]   found $b/$ip_b -> $ib"

  key=${link//-/_}
  printf '%s=%s\n' "${a}__${key}" "$ia" >> state/interfaces.env
  printf '%s=%s\n' "${b}__${key}" "$ib" >> state/interfaces.env
done

for row in "1 R1 H1 172.16.1.2 172.16.1.10" \
           "2 R2 H2 172.16.2.2 172.16.2.10" \
           "3 R11 H3 172.16.3.2 172.16.3.10" \
           "4 R12 H4 172.16.4.2 172.16.4.10"; do
  read -r n router host router_ip host_ip <<< "$row"
  echo "[discover] lan-h$n: $router($router_ip) <-> $host($host_ip)"

  ri=$(find_iface_by_local_ip "$router" "$router_ip")
  echo "[discover]   found $router/$router_ip -> $ri"

  hi=$(find_iface_by_local_ip "$host" "$host_ip")
  echo "[discover]   found $host/$host_ip -> $hi"

  printf '%s=%s\n' "${router}__lan_h${n}" "$ri" >> state/interfaces.env
  printf '%s=%s\n' "${host}__lan_h${n}" "$hi" >> state/interfaces.env
done

count=$(wc -l < state/interfaces.env)
if [[ "$count" -ne 46 ]]; then
  echo "[discover][error] 接口映射数量错误: $count/46" >&2
  exit 1
fi

echo "interface map written to state/interfaces.env ($count entries)"
#这个脚本就是**给整个实验拓扑做 “接口花名册”**：把每个节点上每个链路对应的真实网卡名全部查出来存好，
#后面所有要操作具体网卡的脚本（tc 打损伤、改 OSPF Cost、抓包等），都先加载这个文件，用变量名引用接口，不用硬编码 `ethX`，适配任意启动顺序的 Docker 环境。