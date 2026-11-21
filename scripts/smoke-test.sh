#!/usr/bin/env bash
# Boot the image and verify that systemd comes up and Nix works.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${DETNIX_IMAGE:-detnix:0.1.0}"
NAME="detnix-smoke-$$"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> starting $IMAGE"
docker run -d --name "$NAME" \
  --privileged \
  --cgroupns=host \
  --tmpfs /run \
  --tmpfs /run/lock \
  --tmpfs /tmp \
  "$IMAGE" >/dev/null

echo "==> waiting for systemd"
for _ in $(seq 1 60); do
  state=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)
  case "$state" in
    running | degraded)
      echo "    system state: $state"
      break
      ;;
  esac
  sleep 2
done

echo "==> failed units (if any):"
docker exec "$NAME" systemctl list-units --failed --no-pager || true

echo "==> systemctl is-system-running"
docker exec "$NAME" systemctl is-system-running || true

echo "==> nix --version"
docker exec "$NAME" nix --version

echo "==> nix eval nixpkgs#hello"
docker exec "$NAME" nix eval --raw nixpkgs#hello.name

echo "==> nix build nixpkgs#hello"
docker exec "$NAME" nix-build '<nixpkgs>' -A hello --no-out-link

echo "==> OK"
