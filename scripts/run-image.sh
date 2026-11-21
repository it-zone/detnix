#!/usr/bin/env bash
# Run the detnix image.
#
#   ./scripts/run-image.sh                       # unprivileged shell (default)
#   ./scripts/run-image.sh nix --version        # single command
#   ./scripts/run-image.sh --systemd            # with systemd as PID 1
#   ./scripts/run-image.sh -- --volume "$PWD:/work"   # extra docker flags after --
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${DETNIX_IMAGE:-detnix:0.1.0}"

mode="unprivileged"
if [[ "${1:-}" == "--systemd" ]]; then
  mode="systemd"
  shift
fi

extra=()
if [[ "${1:-}" == "--" ]]; then
  shift
  extra=("$@")
fi

if [[ "$mode" == "systemd" ]]; then
  # systemd needs to manage cgroups and wants a writable /run, /run/lock
  # and /tmp.
  exec docker run --rm -it \
    --user root \
    --privileged \
    --cgroupns=host \
    --tmpfs /run \
    --tmpfs /run/lock \
    --tmpfs /tmp \
    "${extra[@]}" \
    "$IMAGE" "$@"
fi

exec docker run --rm -it \
  "${extra[@]}" \
  "$IMAGE" "$@"
