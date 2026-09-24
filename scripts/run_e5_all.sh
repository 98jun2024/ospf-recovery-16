#!/usr/bin/env bash
# 依次跑 E5 的 S2/S5/S6（每组只跑 1 次）。用法：./scripts/run_e5_all.sh
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
for s in s2 s5 s6; do
  echo "===== E5 scheme=$s ====="
  ./scripts/run.sh scheme "$s"
  sleep 10
  ./scripts/run.sh e5
done
echo "E5 all done; analyze: ./scripts/run.sh analyze-e5"
