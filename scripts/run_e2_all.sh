#!/usr/bin/env bash
# 一键跑 E2 渐变场景的 S2/S5/S6（按精简矩阵，S3/S4 对软恶化无响应，不在 E2 运行）。
# 每个方案：部署 -> 等收敛 -> 跑四阶段渐变。结果在 results/e2/<scheme>-<时间戳>/。
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

for scheme in s2 s5 s6; do
  echo
  echo "==================== E2  $scheme ===================="
  bash scripts/apply_scheme.sh "$scheme"
  SCHEME="$scheme" bash scripts/e2_link_degradation.sh
done

echo
echo "E2 schemes (s2/s5/s6) done. Results:"
ls -1 results/e2/ | sort
