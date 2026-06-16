#!/usr/bin/env bash
# Wrapper used by the systemd unit on the Solid NAS to source .secrets
# (which is shell, not KEY=VALUE — systemd's EnvironmentFile does not
# understand `export`) and then run a make target in the IaC repo.
#
# Usage: wrap.sh <make-target>   (e.g. wrap.sh start-services)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_DIR"

if [[ -f .secrets ]]; then
  # shellcheck disable=SC1091
  . ./.secrets
fi

exec make "$@"
