# The three helpers scripts/edge-probe.sh uses, copied from HEY's private scripts/lib/common.sh.
set -euo pipefail
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
die() {
  printf '%s ERROR: %s\n' "$(utc_now)" "$*" >&2
  exit "${2:-1}"
}
have() { command -v "$1" >/dev/null 2>&1; }
require_cmd() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "required command not found: $cmd"
  done
}
_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${HEY_REPO_DIR:-$(cd "$_common_dir/../.." && pwd)}"
