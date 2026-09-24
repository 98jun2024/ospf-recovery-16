#!/usr/bin/env bash
# 一键跑 E3 硬断链恢复的 S2/S3/S4/S6（按精简矩阵，S5 硬故障收敛与 S2 相当，不跑）。
# 每个方案：部署 -> 等收敛 -> 60s断/20s故障/30s恢复观察。结果在 results/e3/<scheme>-<时间戳>/。
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

for scheme in s2 s3 s4 s6; do
  echo
  echo "==================== E3  $scheme ===================="
  bash scripts/apply_scheme.sh "$scheme"
  SCHEME="$scheme" bash scripts/e3_hard_failure.sh
done

echo
echo "E3 schemes (s2/s3/s4/s6) done. Results:"
ls -1 results/e3/ | sort
