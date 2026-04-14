#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/smoke-test-build-dir.sh [BUILD_DIR]

Smoke-test the built Flatpak app by starting Plex headlessly for a short period.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${1:-$repo_root/flatpak/work/build-dir}"
timeout_seconds="${SMOKE_TEST_TIMEOUT_SECONDS:-20}"

case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac

if [[ ! -d "$build_dir" ]]; then
  echo "Build directory does not exist: $build_dir" >&2
  exit 1
fi

stdout_log="$(mktemp)"
stderr_log="$(mktemp)"
trap 'rm -f "$stdout_log" "$stderr_log"' EXIT

set +e
timeout "${timeout_seconds}s" \
  flatpak build "$build_dir" \
  sh -lc 'env QT_QPA_PLATFORM=offscreen /app/bin/Plex' \
  >"$stdout_log" 2>"$stderr_log"
status=$?
set -e

if [[ "$status" -eq 124 ]]; then
  echo "Smoke test passed: Plex stayed alive for ${timeout_seconds}s."
  exit 0
fi

if [[ "$status" -eq 0 ]]; then
  echo "Smoke test passed: Plex exited cleanly before timeout."
  exit 0
fi

echo "Smoke test failed with exit code $status" >&2
echo "--- stderr ---" >&2
sed -n '1,200p' "$stderr_log" >&2
echo "--- stdout ---" >&2
sed -n '1,120p' "$stdout_log" >&2
exit "$status"
