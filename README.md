# detnix

[![build](https://github.com/it-zone/detnix/actions/workflows/build.yml/badge.svg)](https://github.com/it-zone/detnix/actions/workflows/build.yml)

**Deterministic Systemd Nix** — container images that are the systemd-based
counterpart of [`ghcr.io/nixos/nix:latest`](https://github.com/NixOS/nix).

`ghcr.io/nixos/nix` is a scratch-style image: a flat `/nix/store` with a few
binaries and no init system. `detnix` keeps the same spirit — everything is
built by Nix, nothing by a Dockerfile — but boots a real **NixOS system with
systemd as PID 1**, so the container behaves like a small Linux system with
services, `systemctl`, `/run/current-system` and a proper Nix installation.
As a normal user it runs without a Nix daemon at all (`NIX_REMOTE=local`).

| | `ghcr.io/nixos/nix:latest` | `ghcr.io/it-zone/detnix:latest` |
|---|---|---|
| Base | Nix store + a few packages | NixOS system closure (`/init` → systemd) |
| PID 1 | your command | systemd (unless you pass a command) |
| Nix | upstream Nix 2.36.0 | **Determinate Nix**, built from source |
| Nixpkgs | bundled as a channel | `nixpkgs-unstable` source shipped in the image, refreshed on every build |
| Init system | none | systemd (NixOS) |
| Build recipe | `dockerTools.buildLayeredImageWithNixDb` | `dockerTools.buildLayeredImageWithNixDb` |
| Architectures | amd64, arm64 | amd64, arm64 |

## Features

- **Deterministic** — the image is a Nix derivation. Identical inputs produce a
  byte-identical image digest. No `Dockerfile`, no timestamps, no host state.
- **Always fresh** — CI refreshes the `nixpkgs-unstable` and Determinate Nix
  inputs before every build, so `:latest` always tracks upstream.
- **Systemd** — `systemctl` works, services start, the system shuts down
  cleanly on `docker stop`.
- **Content-addressed store** — the Nix database is baked into the image, so
  `nix-store --query --requisites` and garbage collection work out of the box.
- **Works offline** — the nixpkgs source is part of the image, so `nix eval
  nixpkgs#hello` and `nix build '<nixpkgs>' -A hello` evaluate without a
  channel and without network access (the built binaries themselves are
  fetched from the binary cache, as usual).
- **Runs as a normal user** — the image starts as the unprivileged user
  `detnix` (uid 1000). Nix works without root and without a Nix daemon
  (`NIX_REMOTE=local`): the store directory and the Nix database are writable
  for that user, `/etc` is a writable copy.
- **Multi-arch** — `x86_64-linux` and `aarch64-linux`, published as a single
  manifest list.

## Usage

The image runs as the unprivileged user `detnix` (uid 1000) by default — no
privileged container needed:

```bash
docker run --rm -it ghcr.io/it-zone/detnix:latest
docker run --rm -it -v "$PWD:/work" ghcr.io/it-zone/detnix:latest
```

```console
$ id
uid=1000(detnix) gid=1000(users) groups=1000(users)
$ nix --version
nix (Determinate Nix 3.24.3) 2.35.6
$ nix build '<nixpkgs>' -A hello
```

The same image is also published as `:latest-root`, which starts as root
instead:

```bash
docker run --rm -it ghcr.io/it-zone/detnix:latest-root
```

To boot the full NixOS system with systemd as PID 1, run it as root in a
privileged container:

```bash
docker run --rm -it \
  --user root --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  ghcr.io/it-zone/detnix:latest
```

Inside:

```console
$ systemctl is-system-running
running
$ nix --version
nix (Determinate Nix 3.24.3) 2.35.6
$ nix build '<nixpkgs>' -A hello
$ nix profile install nixpkgs#hello
$ hello
```

### Running a single command (no systemd)

Like the upstream image, you can run a command directly — the entrypoint
dispatches to it:

```bash
docker run --rm ghcr.io/it-zone/detnix:latest nix --version
docker run --rm -v "$PWD:/work" ghcr.io/it-zone/detnix:latest nix build /work#default
```

`/usr/local/bin` contains symlinks to `nix`, `bash`, `coreutils`, `curl`,
`wget`, `tar`, `gzip`, `jq`, `grep`, `sed`, `awk` and `which`, plus every
binary of the NixOS system path (`git`, `ssh`, …). `/bin/sh` and `/bin/bash`
exist as well (CI systems and container runtimes call `/bin/sh` directly);
unknown commands are handed to `bash` instead of failing. `/etc` is a writable
copy of the NixOS one — note that container runtimes mount the host's
`/etc/hosts` over it, see [Publishing](#publishing) for the root flavour.

### Why `--privileged --cgroupns=host`?

systemd needs to create its own scopes and cgroups, and it wants a writable
`/run`, `/run/lock` and `/tmp`. In rootless or unprivileged containers systemd
cannot manage cgroups and the boot will fail with
`Failed to create /init.scope control group`. The flags above are the standard
recipe for running systemd in Docker; drop `--privileged` only if you accept
that systemd will not manage services.

Without systemd — the default mode of this image — none of that is needed: the
container runs as the unprivileged user `detnix` and Nix works with its own
writable store.

## Building locally

```bash
nix build .#image          # → ./result (a zstd-compressed docker archive)
nix build .#imageRoot      # → ./result-1 (the same image, starting as root)
docker load -i result      # docker ≥ 25 reads .tar.zst directly
docker run --rm -it detnix:0.1.0                       # unprivileged
docker run --rm -it detnix:0.1.0-root                  # as root
docker run --rm -it --user root --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp detnix:0.1.0   # with systemd
```

or with the helper scripts:

```bash
./scripts/build-image.sh --update   # refresh inputs + build + docker load
./scripts/run-image.sh               # unprivileged shell
./scripts/run-image.sh --systemd     # with systemd as PID 1
./scripts/smoke-test.sh              # boot it and check systemd + nix
```

`--update` runs `nix flake update` first, which moves `nixpkgs` to the newest
`nixpkgs-unstable` and `DeterminateSystems/nix-src` to the newest Determinate
Nix release.

## Publishing

`.github/workflows/build.yml` builds both architectures natively
(`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64), smoke-tests the
image, pushes the per-architecture tags and assembles the multi-arch manifest
list:

```
ghcr.io/it-zone/detnix:latest              # multi-arch manifest
ghcr.io/it-zone/detnix:0.1.0               # multi-arch manifest
ghcr.io/it-zone/detnix:latest-amd64        # single arch
ghcr.io/it-zone/detnix:latest-arm64
ghcr.io/it-zone/detnix:0.1.0-amd64
ghcr.io/it-zone/detnix:0.1.0-arm64
```

Two flavours of the same image are published: the default one starts as the
unprivileged user `detnix`, the `:latest-root` / `:0.1.0-root` ones start as
root.

```bash
ghcr.io/it-zone/detnix:latest-root         # multi-arch manifest, runs as root
ghcr.io/it-zone/detnix:latest-root-amd64
ghcr.io/it-zone/detnix:latest-root-arm64
ghcr.io/it-zone/detnix:0.1.0-root
```

Use the root flavour when the job has to write to `/etc/hosts`: container
runtimes mount the *host's* `/etc/hosts` over the one in the image, and that
file belongs to root, so an unprivileged job cannot append to it. Everything
else (Nix builds, `~/.config/nix/nix.conf`, the Nix database, the store) works
as the unprivileged user.

Triggers: pushes to `main`, `v*` tags, a daily schedule and manual dispatch.
Documentation-only pushes are ignored — they do not rebuild the image.

The build compiles Determinate Nix from source (the `DeterminateSystems/nix-src`
flake) and the NixOS system, which takes roughly 25 minutes per architecture
without a warm Nix store cache. The `magic-nix-cache-action` step shares the
store between runs when the cache service is reachable; a cache outage only
costs build time, it does not fail the run.

## Repository layout

```
flake.nix                     # image, toplevel, checks, devShells
nix/modules/detnix.nix        # the NixOS module that shapes the system
scripts/build-image.sh        # build + docker load
scripts/run-image.sh          # run the image (--systemd for the systemd mode)
scripts/smoke-test.sh         # boot test: systemd, nix, nix-build
.github/workflows/build.yml   # build, test, publish to ghcr.io
```

### How the image is assembled

1. `nix/modules/detnix.nix` configures a NixOS system:
   `boot.isContainer = true` (from `virtualisation/docker-image.nix`),
   systemd without getty units, a fixed `machine-id`, no firewall, no initrd,
   `nix.package` = Determinate Nix, `sandbox = false`,
   `experimental-features = nix-command flakes`.
2. `config.system.build.toplevel` provides `/init` (the stage-2 activation
   script), `/etc`, `/sw` and `/systemd`.
3. `dockerTools.buildLayeredImageWithNixDb` puts the closure into `/nix/store`
   inside the image, layers it per store path, and bakes the Nix database.
4. The nixpkgs source is added to the image as well and put into `NIX_PATH`,
   so `<nixpkgs>` resolves without a channel and without network access.
5. `extraCommands` writes the `/entrypoint` dispatcher and the
   `/usr/local/bin` symlinks. The dispatcher boots systemd as PID 1 when the
   container runs as root with `CAP_SYS_ADMIN`, and hands the command to bash
   otherwise — so the same image works as a plain Nix container and as a
   systemd system.
6. The image is owned by the unprivileged user `detnix` (uid 1000): `/etc` is
   a writable copy, `/nix/store` is writable (1777) and the Nix database
   belongs to that user, so Nix can build without root and without a daemon.

## Determinism notes

- The image archive is compressed with **zstd** (`compressor = "zstd"`), not
  gzip — smaller and much faster to decompress.
- `created = "1970-01-01T00:00:01Z"` in the image config.
- Layer tarballs are created with `SOURCE_DATE_EPOCH` (nixpkgs default
  315532800) and sorted, so layer order and mtimes are stable.
- The Nix database is registered with `registrationTime = SOURCE_DATE_EPOCH`.
- The `machine-id` is baked into the image instead of being generated at boot.
- With an unchanged `flake.lock`, `nix build .#image` yields the same digest on
  every machine and every architecture. Verified locally by deleting the image
  derivation from the store and building it again:

  ```bash
  nix build .#image
  nix-store --delete "$(readlink -f result)"
  nix build .#image        # → same store path, same sha256
  ```

## License

MIT — see [LICENSE](LICENSE).
