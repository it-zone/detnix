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
# `result` is a symlink: resolve it, the decompressors skip symlinks.
archive="$(readlink -f result)"
case "$archive" in
  *.zst) zstd -dc "$archive" | docker load ;;
  *.gz) gzip -dc "$archive" | docker load ;;
  *) docker load -i "$archive" ;;
esac

echo "==> done:"
docker image ls detnix
