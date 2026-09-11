#!/bin/bash
set -euo pipefail
backend_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PYTHON_BIN:-}" ]]; then
  backend_python="$PYTHON_BIN"
elif command -v python3.14 >/dev/null 2>&1; then
  backend_python="$(command -v python3.14)"
else
  backend_python="$(command -v python3)"
fi
exec "$backend_python" "$backend_dir/install-service.py" prepare "$@"
