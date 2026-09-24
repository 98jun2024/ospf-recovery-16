#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CMD="${1:-help}"
case "$CMD" in
  up) bash "$ROOT/scripts/up.sh" ;;
  addresses) echo '[run] configuring fixed addresses'; timeout "${ADDRESS_TIMEOUT:-600}" bash "$ROOT/scripts/configure_addresses.sh" ;;
  configs) python3 "$ROOT/scripts/generate_configs.py" ;;
  ospf) bash "$ROOT/scripts/apply_ospf.sh" ;;
  scheme) bash "$ROOT/scripts/apply_scheme.sh" "${2:-}" ;;
  e1) bash "$ROOT/scripts/e1_baseline.sh" ;;
  e1-all) bash "$ROOT/scripts/run_e1_all.sh" ;;
  e2) bash "$ROOT/scripts/e2_link_degradation.sh" ;;
  e2-all) bash "$ROOT/scripts/run_e2_all.sh" ;;
  e3) bash "$ROOT/scripts/e3_hard_failure.sh" ;;
  e3-all) bash "$ROOT/scripts/run_e3_all.sh" ;;
  e4) bash "$ROOT/scripts/e4_node_failure.sh" ;;
  e4-all) bash "$ROOT/scripts/run_e4_all.sh" ;;
  e5) bash "$ROOT/scripts/e5_random_disturbance.sh" ;;
  e5-all) bash "$ROOT/scripts/run_e5_all.sh" ;;
  analyze-e1) bash "$ROOT/scripts/analyze_e1.sh" "${@:2}" ;;
  analyze-e2) bash "$ROOT/scripts/analyze_e2.sh" "${@:2}" ;;
  analyze-e3) bash "$ROOT/scripts/analyze_e3.sh" "${@:2}" ;;
  analyze-e4) bash "$ROOT/scripts/analyze_e4.sh" "${@:2}" ;;
  analyze-e5) bash "$ROOT/scripts/analyze_e5.sh" "${@:2}" ;;
  check) bash "$ROOT/scripts/check_ospf.sh" && bash "$ROOT/scripts/check_connectivity.sh" ;;
  down) bash "$ROOT/scripts/down.sh" ;;
  reset) bash "$ROOT/scripts/reset.sh" ;;
  *) echo 'usage: ./scripts/run.sh {up|addresses|configs|ospf|scheme <s2..s6>|e1|e1-all|e2|e2-all|e3|e3-all|e4|e4-all|e5|e5-all|analyze-e1|analyze-e2|analyze-e3|analyze-e4|analyze-e5|check|down|reset}' ; exit 2 ;;
esac
