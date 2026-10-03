#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ERROR[TOOL]: 缺少 Python 3" >&2; exit 12; }
exec python3 -B "$ROOT/Scripts/verify_ipa.py" "$@"
