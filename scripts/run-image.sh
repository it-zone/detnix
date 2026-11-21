#!/usr/bin/env bash
# Run the detnix image with the flags systemd needs inside a container.
#
#   ./scripts/run-image.sh                       # interactive shell
#   ./scripts/run-image.sh nix --version        # single command
#   ./scripts/run-image.sh -- -A                 # extra docker flags after --
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${DETNIX_IMAGE:-detnix:0.1.0}"

extra=()
if [[ "${1:-}" == "--" ]]; then
  shift
  extra=("$@")
fi

exec docker run --rm -it \
  --privileged \
  --cgroupns=host \
  --tmpfs /run \
  --tmpfs /run/lock \
  --tmpfs /tmp \
  "${extra[@]}" \
  "$IMAGE" "$@"
