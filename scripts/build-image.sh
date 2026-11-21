#!/usr/bin/env bash
# Build the detnix image locally and load it into Docker.
#
#   ./scripts/build-image.sh            # build with the locked inputs
#   ./scripts/build-image.sh --update   # refresh inputs first (newest nixpkgs-unstable)
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--update" ]]; then
  echo "==> refreshing flake inputs (newest nixpkgs-unstable + newest Determinate Nix)"
  nix flake update
fi

echo "==> building .#image"
nix build .#image --print-build-logs

echo "==> loading image into Docker"
case "$(readlink -f result)" in
  *.zst) zstd -dc result | docker load ;;
  *.gz) gzip -dc result | docker load ;;
  *) docker load -i result ;;
esac

echo "==> done:"
docker image ls detnix
