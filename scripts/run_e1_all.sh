#!/usr/bin/env bash
# 一键跑 E1 的 S2-S6 全部方案。
# 按精简版实验矩阵，E1 所有方案都执行；每个方案部署后等收敛，再采集基线。
# 结果目录：results/e1/<scheme>-<timestamp>/
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

for scheme in s2 s3 s4 s5 s6; do
  echo
  echo "==================== E1  $scheme ===================="
  bash scripts/apply_scheme.sh "$scheme"
  SCHEME="$scheme" bash scripts/e1_baseline.sh
done

echo
echo "E1 all schemes (s2-s6) done. Results:"
ls -1 results/e1/ | sort
