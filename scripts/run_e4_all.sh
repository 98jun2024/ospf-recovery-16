#!/usr/bin/env bash
# 一键跑 E4 节点故障（docker stop/start R5）的 S2/S3/S4/S6（按精简矩阵，S5 硬故障收敛与 S2 相当，不跑）。
# 每个方案：部署 -> 等收敛 -> 60s 基线 / 停 R5 20s / start 后观察 45s。结果在 results/e4/<scheme>-时间戳/。
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

for scheme in s2 s3 s4 s6; do
  echo
  echo "==================== E4  $scheme ===================="
  bash scripts/apply_scheme.sh "$scheme"
  SCHEME="$scheme" bash scripts/e4_node_failure.sh
done

echo
echo "E4 schemes (s2/s3/s4/s6) done. Results:"
ls -1 results/e4/ | sort
