#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"; source scripts/common.sh
"${COMPOSE[@]}" exec -T --interactive=false H1 ping -c 3 172.16.3.10
"${COMPOSE[@]}" exec -T --interactive=false H2 ping -c 3 172.16.4.10
