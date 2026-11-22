{
  description = "Detnix — Deterministic Systemd Nix container images";

  inputs = {
    # Base system: always the newest nixpkgs-unstable.
    # CI refreshes this pin on every image build (see .github/workflows/build.yml).
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Nix itself: Determinate Nix, built from source so the image is
    # content-addressed and reproducible.
    determinate-nix.url = "github:DeterminateSystems/nix-src";
  };

  outputs = {
    self,
    nixpkgs,
    determinate-nix,
    ...
  }: let
    inherit (nixpkgs) lib;

    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    forAllSystems = lib.genAttrs systems;

    version = "0.1.0";

    # Deterministic image metadata. `created` is pinned to the Unix epoch so
    # that identical inputs always produce an identical image digest.
    created = "1970-01-01T00:00:01Z";
  in {
    packages = forAllSystems (
      system: let
        pkgs = import nixpkgs {inherit system;};

        # Determinate Nix (nix + nix-daemon + man pages), built from source.
        #
        # The upstream package runs its own test suite in the check phase.
        # That suite is slow and flaky on CI (it failed on aarch64 in run
        # 44923402895) and we only need the binaries, so it is disabled here.
        determinateNix = determinate-nix.packages.${system}.nix.overrideAttrs (
          old: {
            doCheck = false;
          }
        );

        nixosSystem = lib.nixosSystem {
          inherit system;
          modules = [
            ./nix/modules/detnix.nix
            {
              nixpkgs.hostPlatform = system;
              detnix.nixPackage = determinateNix;
            }
          ];
        };

        toplevel = nixosSystem.config.system.build.toplevel;

        # The nixpkgs source is shipped with the image, so that the container
        # has a working <nixpkgs> offline, exactly like the upstream
        # nixos/nix image ships its nixpkgs channel.
        #
        # It is referenced through a tiny derivation instead of being added to
        # `contents` directly: `contents` entries are merged into the image
        # root, which would splatter the nixpkgs source tree (etc/, lib/,
        # pkgs/, …) over the root and shadow the NixOS /etc.
        nixpkgsSource = pkgs.runCommand "nixpkgs-source" {} ''
          mkdir -p $out
          ln -s ${pkgs.path} $out/nixpkgs
        '';

        # The image is built purely with Nix (no Dockerfile, no podman), so the
        # whole container filesystem is content-addressed.
        #
        # The user the container starts as is the only difference between the
        # two flavours of the image.
        mkImage = imageUser: imageTag:
          pkgs.dockerTools.buildLayeredImageWithNixDb {
            name = "detnix";
            tag = imageTag;
            inherit created;

            # The NixOS system closure. dockerTools puts the whole closure into
            # /nix/store inside the image and layers it per store path.
            contents = [
              toplevel
              nixpkgsSource
            ];

            maxLayers = 100;

            # Everything inside the image belongs to the unprivileged user, so
            # that Nix can build without root and without a Nix daemon - which
            # is what makes the image usable in unprivileged containers.
            uid = "1000";
            gid = "1000";
            uname = "detnix";
            gname = "detnix";

            # zstd instead of gzip: smaller and much faster to decompress.
            compressor = "zstd";

            # Convenience symlinks so that `docker run detnix nix --version`
            # works even when systemd is not PID 1.
            extraCommands = ''
              mkdir -p usr/local/bin
              for exe in nix nix-build nix-env nix-shell nix-store nix-instantiate nix-daemon; do
                if [ -e ${determinateNix}/bin/$exe ]; then
                  ln -s ${determinateNix}/bin/$exe usr/local/bin/$exe
                fi
              done

              # A shell and the usual suspects, so that a single command can
              # also be run without booting systemd.
              for pkg in ${pkgs.bashInteractive} ${pkgs.coreutils} ${pkgs.coreutils-full} \
                         ${pkgs.curl} ${pkgs.gawk} ${pkgs.gnugrep} ${pkgs.gnused} \
                         ${pkgs.gnutar} ${pkgs.gzip} ${pkgs.jq} \
                         ${pkgs.which} ${pkgs.wget}; do
                for exe in $pkg/bin/*; do
                  if [ -x "$exe" ]; then
                    ln -sf "$exe" "usr/local/bin/$(basename "$exe")"
                  fi
                done
              done

              # Everything the NixOS system itself provides (git, ssh, …). The
              # system path is only reachable through /run/current-system after
              # systemd has booted, so the binaries are linked into
              # /usr/local/bin as well: the image is usable without systemd.
              for exe in ${nixosSystem.config.system.path}/bin/*; do
                if [ -e "$exe" ]; then
                  ln -sf "$exe" "usr/local/bin/$(basename "$exe")"
                fi
              done

              # A POSIX shell at the well known place: CI systems and container
              # runtimes call /bin/sh directly, and a NixOS system does not have
              # one before systemd has booted.
              mkdir -p bin
              ln -sf ${pkgs.bashInteractive}/bin/bash bin/bash
              ln -sf ${pkgs.bashInteractive}/bin/bash bin/sh

              # Directories the NixOS activation script and the unprivileged
              # user need. They are part of the image so that the image also
              # works without booting systemd.
              mkdir -p home/${nixosSystem.config.detnix.user} tmp var run root
              chmod 1777 tmp

              # The unprivileged user owns its home directory, the Nix database
              # and the store directory, so that Nix can build without root and
              # without a Nix daemon. The ownership itself is set in
              # fakeRootCommands below (the sandbox has no uid 1000 mapped, but
              # fakeroot can fake it). The store paths stay read-only, only the
              # directory itself is writable.
              mkdir -p nix/store
              chmod 1777 nix/store

              # /etc has to be writable as well: CI systems append to
              # /etc/hosts for example. The NixOS /etc is a symlink into the
              # read-only store, so it is replaced by a writable copy. Symlinks
              # inside it are kept and still point into the store.
              if [ -L etc ]; then
                etc_target="$(readlink -f etc)"
                mkdir -p .etc-copy
                cp -a "$etc_target"/. .etc-copy/
                rm etc
                mv .etc-copy etc
              fi
              find etc -type d -exec chmod u+w {} +
              find etc -type f -exec chmod u+w {} +

              # CI systems append to /etc/hosts (and friends) while running as
              # the unprivileged user, so those files have to be writable for
              # everybody - the image is not a security boundary here.
              # Symlinks into the read-only store are replaced by copies, a
              # chmod on them would fail.
              for f in etc/hosts etc/resolv.conf etc/hostname; do
                if [ -L "$f" ]; then
                  cp -L "$f" "$f.detnix-copy" && mv -f "$f.detnix-copy" "$f"
                fi
                if [ -f "$f" ]; then chmod 0666 "$f"; fi
              done

              # /etc/passwd and /etc/group are generated by the NixOS activation
              # script, which needs to *write* them. They are therefore created
              # as regular files (not as symlinks into the read-only store) with
              # a minimal content: the activation script merges the system users
              # into them on boot, and without them Nix cannot resolve the home
              # directory of the unprivileged user the image runs as.
              cat > etc/passwd <<EOF
              root:x:0:0:root:/root:/run/current-system/sw/bin/bash
              ${nixosSystem.config.detnix.user}:x:${toString nixosSystem.config.detnix.uid}:${toString nixosSystem.config.detnix.uid}:${nixosSystem.config.detnix.user}:/home/${nixosSystem.config.detnix.user}:/run/current-system/sw/bin/bash
              EOF
              cat > etc/group <<EOF
              root:x:0:
              users:x:${toString nixosSystem.config.detnix.uid}:
              ${nixosSystem.config.detnix.user}:x:${toString nixosSystem.config.detnix.uid}:
              EOF
              chmod 0644 etc/passwd etc/group

              # Dispatcher: without arguments systemd boots as PID 1 (which
              # needs root and a privileged container), with arguments the
              # command is executed directly.
              # The interpreter is addressed by its store path, because a
              # NixOS system has no /bin/sh before systemd has booted.
              cat > entrypoint <<'EOF'
              #!${pkgs.bashInteractive}/bin/bash
              set -e

              # HOME and USER depend on the user the container runs as: the
              # unprivileged user by default, root when the container is
              # started with --user root.
              if [ "$(id -u)" -eq 0 ]; then
                export HOME=/root
                export USER=root
              else
                export HOME=/home/${nixosSystem.config.detnix.user}
                export USER=${nixosSystem.config.detnix.user}
              fi

              # systemd can only be PID 1 when we are root and the container is
              # privileged enough to manage mounts and cgroups.
              have_systemd() {
                [ "$(id -u)" -eq 0 ] || return 1
                # Read /proc/self/status with bash builtins only: the image
                # must not depend on awk or grep being present.
                local line capeff=""
                while IFS= read -r line; do
                  case "$line" in
                    CapEff:*) capeff="''${line#CapEff:}" ;;
                  esac
                done < /proc/self/status
                capeff="''${capeff//[[:space:]]/}"
                [ -n "$capeff" ] || return 1
                # CAP_SYS_ADMIN is bit 21
                [ $(( 0x$capeff & 0x200000 )) -ne 0 ]
              }

              if [ "$#" -eq 0 ]; then
                if have_systemd; then
                  exec /init
                fi
                set -- bash
              fi

              # Shell requests are run through bash: a NixOS system has no
              # /bin/sh.
              case "''${1:-}" in
                sh | dash | ash) shift ;;
              esac
              if [ "$#" -eq 0 ] || ! command -v "$1" >/dev/null 2>&1; then
                set -- bash "$@"
              fi
              exec "$@"
              EOF
              chmod 0755 entrypoint
            '';

            # Ownership of the writable parts of the image. These commands run
            # inside fakeroot: the Nix sandbox has no uid 1000 in its user
            # namespace (a plain chown would fail with "Invalid argument"),
            # but fakeroot can fake any uid - and the tar of this layer is
            # written by the same fakeroot, so the fake ownership ends up in
            # the image.
            fakeRootCommands = ''
              chown -Rh ${toString nixosSystem.config.detnix.uid}:${toString nixosSystem.config.detnix.uid} \
                home/${nixosSystem.config.detnix.user} nix/var
            '';

            config = {
              Entrypoint = ["/entrypoint"];
              Cmd = [];

              Env = [
                # No HOME/USER here: they depend on the user the container runs
                # as. The entrypoint exports them (root or the unprivileged
                # user), and Nix falls back to /etc/passwd otherwise - which
                # avoids the "$HOME is not owned by you" warning.
                "PATH=/usr/local/bin:/run/current-system/sw/bin:/home/${nixosSystem.config.detnix.user}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/default/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                "MANPATH=/home/${nixosSystem.config.detnix.user}/.nix-profile/share/man:/nix/var/nix/profiles/default/share/man"
                "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
                "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                "NIX_PATH=nixpkgs=${pkgs.path}"
                "TMPDIR=/tmp"
                "NIX_REMOTE=local"
                "container=docker"
              ];

              WorkingDir = "/";

              # The image runs as the unprivileged user by default, so that Nix
              # can build without root and the image works in unprivileged
              # containers. The "imageRoot" flavour starts as root instead.
              User = imageUser;

              # Let systemd shut the container down cleanly instead of SIGTERM.
              StopSignal = "SIGRTMIN+3";

              Labels = {
                "org.opencontainers.image.title" = "detnix";
                "org.opencontainers.image.description" = "Deterministic Systemd Nix container image";
                "org.opencontainers.image.source" = "https://github.com/it-zone/detnix";
                "org.opencontainers.image.vendor" = "IT ZONE";
                "org.opencontainers.image.version" = version;
                "org.opencontainers.image.licenses" = "MIT";
              };
            };
          };

        # The default flavour: the container starts as the unprivileged user
        # "detnix" (uid 1000). Nix works without root and without a daemon.
        image = mkImage "${toString nixosSystem.config.detnix.uid}:${toString nixosSystem.config.detnix.uid}" version;

        # The same image, but starting as root: CI jobs that append to
        # /etc/hosts need it, because container runtimes mount the host's
        # /etc/hosts over the one inside the image.
        imageRoot = mkImage "0:0" "${version}-root";
      in {
        inherit toplevel image imageRoot;

        default = image;
      }
    );

    checks = forAllSystems (
      system: let
        flake = self.packages.${system};
      in {
        image = flake.image;
        toplevel = flake.toplevel;
      }
    );

    devShells = forAllSystems (
      system: let
        pkgs = import nixpkgs {inherit system;};
      in {
        default = pkgs.mkShell {
          packages = [
            pkgs.docker
            pkgs.skopeo
            pkgs.zstd
            pkgs.coreutils
          ];
        };
      }
    );

    formatter = forAllSystems (system: (import nixpkgs {inherit system;}).alejandra);
  };
}
