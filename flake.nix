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
        determinateNix = determinate-nix.packages.${system}.nix;

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

        # The image is built purely with Nix (no Dockerfile, no podman), so the
        # whole container filesystem is content-addressed.
        image = pkgs.dockerTools.buildLayeredImageWithNixDb {
          name = "detnix";
          tag = version;
          inherit created;

          # The NixOS system closure. dockerTools puts the whole closure into
          # /nix/store inside the image and layers it per store path.
          #
          # pkgs.path (the nixpkgs source) is added as well so that the
          # container ships a working <nixpkgs> offline, exactly like the
          # upstream nixos/nix image ships its nixpkgs channel.
          contents = [
            toplevel
            pkgs.path
          ];

          maxLayers = 100;

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
                       ${pkgs.curl} ${pkgs.gnutar} ${pkgs.gzip} ${pkgs.jq} \
                       ${pkgs.which} ${pkgs.wget}; do
              for exe in $pkg/bin/*; do
                if [ -x "$exe" ]; then
                  ln -sf "$exe" "usr/local/bin/$(basename "$exe")"
                fi
              done
            done

            # Dispatcher: without arguments systemd boots as PID 1,
            # with arguments the command is executed directly.
            # The interpreter is addressed by its store path, because a
            # NixOS system has no /bin/sh before systemd has booted.
            cat > entrypoint <<'EOF'
            #!${pkgs.bashInteractive}/bin/bash
            set -e
            if [ "$#" -eq 0 ]; then
              exec /init
            fi
            # A NixOS system has no /bin/sh, so unknown commands are run
            # through bash instead of failing.
            if ! command -v "$1" >/dev/null 2>&1; then
              set -- bash "$@"
            fi
            exec "$@"
            EOF
            chmod 0755 entrypoint
          '';

          config = {
            Entrypoint = ["/entrypoint"];
            Cmd = [];

            Env = [
              "USER=root"
              "HOME=/root"
              "PATH=/usr/local/bin:/run/current-system/sw/bin:/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/default/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
              "MANPATH=/root/.nix-profile/share/man:/nix/var/nix/profiles/default/share/man"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
              "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "NIX_PATH=nixpkgs=${pkgs.path}:/nix/var/nix/profiles/per-user/root/channels:/root/.nix-defexpr/channels"
              "container=docker"
            ];

            WorkingDir = "/";
            User = "0:0";

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
      in {
        inherit image toplevel;

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
