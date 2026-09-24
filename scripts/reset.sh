#!/usr/bin/env bash
set -Eeuo pipefail
"$(cd "$(dirname "$0")" && pwd)/down.sh"
rm -rf frr/generated state
mkdir -p frr/generated state
echo 'runtime state reset; images and source configuration were kept'
