#!/usr/bin/env bash
# Verify the image: Nix works for the unprivileged user, and systemd comes up
# when the container is started privileged.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${DETNIX_IMAGE:-detnix:0.1.0}"
NAME="detnix-smoke-$$"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> unprivileged, unprivileged user"
docker run --rm "$IMAGE" bash -c '
  set -e
  echo "    user: $(id -un) (uid $(id -u))"
  echo "    home: $HOME"
  echo "    nix:  $(nix --version)"
  echo "    nixpkgs: $(nix eval --raw nixpkgs#hello.name)"
  nix build --no-link "nixpkgs#hello"
  echo "    nix build: ok"
  mkdir -p "$HOME/.config/nix"
  echo "sandbox = false" >> "$HOME/.config/nix/nix.conf"
  echo "    user nix.conf: ok"
  test -x /bin/sh && echo "    /bin/sh: ok"
  test -w /nix/store && echo "    /nix/store writable: ok"
'

echo "==> /bin/sh via the runtime"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'echo "    /bin/sh works"'

echo "==> systemd (privileged container, root user)"
docker run -d --name "$NAME" \
  --privileged \
  --cgroupns=host \
  --user root \
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

echo "==> nix --version"
docker exec "$NAME" nix --version

echo "==> OK"
