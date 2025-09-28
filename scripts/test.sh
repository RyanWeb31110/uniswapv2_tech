#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/forge-test-$TIMESTAMP.log"

cd "$PROJECT_ROOT"

echo "[scripts/test.sh] forge test $*" | tee "$LOG_FILE"
forge test "$@" 2>&1 | tee -a "$LOG_FILE"
