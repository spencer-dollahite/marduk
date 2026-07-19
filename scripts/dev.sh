#!/bin/bash
# dev.sh — Build and start Marduk daemon (foreground).
# Use 'marduk update' from another terminal to hot-reload.
set -euo pipefail

echo "[dev] Building..."
swift build || exit 1

echo "[dev] Starting Marduk daemon..."
exec .build/debug/marduk start "$@"
