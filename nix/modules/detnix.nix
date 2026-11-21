{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  cfg = config.detnix;
in {
  # docker-image.nix gives us the container conventions that NixOS itself
  # supports: boot.isContainer = true, no firewall, no socket-activated sshd.
  imports = ["${modulesPath}/virtualisation/docker-image.nix"];

  options.detnix = {
    nixPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nix;
      defaultText = lib.literalExpression "pkgs.nix";
      description = ''
        The Nix package that is installed into the image. The flake sets this
        to Determinate Nix, built from source.
      '';
    };

    machineId = lib.mkOption {
      type = lib.types.str;
      default = "d3tn1x0000000000000000000000000";
      description = ''
        Fixed machine-id. Baking it in keeps the image byte-for-byte
        reproducible and lets systemd boot without a writable /etc.
      '';
    };

    nixpkgsPath = lib.mkOption {
      type = lib.types.str;
      default = toString pkgs.path;
      defaultText = lib.literalExpression "toString pkgs.path";
      description = ''
        Path to the nixpkgs source that is shipped inside the image. It is put
        into NIX_PATH so that <nixpkgs> works offline.
      '';
    };
  };

  config = {
    # --- Nix -----------------------------------------------------------------

    nix.package = cfg.nixPackage;

    nix.settings = {
      # Containers cannot use Nix's build sandbox (no user namespaces, no
      # mount privileges), so builds run unconfined inside the container.
      sandbox = false;

      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Root is trusted (as on a normal NixOS install).
      trusted-users = ["root"];

      # Empty group => builds run as the invoking user instead of nixbld
      # users, which do not exist in a container.
      build-users-group = "";

      warn-dirty = false;
    };

    # /lib/ld-linux*.so.2 is needed to run dynamically linked binaries that
    # were not built by Nix inside the container.
    programs.nix-ld.enable = true;

    # --- systemd -------------------------------------------------------------

    # No initrd: the container boots from the userspace store.
    boot.initrd.enable = false;

    # There is no console attached to the container, so the getty units would
    # just fail (and keep the system in "starting" state).
    systemd.units."serial-getty@hvc0.service".enable = false;
    systemd.units."getty@tty1.service".enable = false;
    systemd.units."systemd-ask-password-console.path".enable = false;

    # Upstream systemd units that cannot work inside a container: there is
    # no kernel debugfs/tracing, and the image filesystem is not persistent
    # enough to save a machine-id. Suppressing them keeps the system in the
    # "running" state instead of "degraded".
    systemd.suppressedSystemUnits = [
      "sys-kernel-debug.mount"
      "sys-kernel-tracing.mount"
      "systemd-machine-id-commit.service"
    ];

    # Fixed machine-id, see detnix.machineId.
    environment.etc."machine-id".text = cfg.machineId;

    # --- system --------------------------------------------------------------

    networking.hostName = "detnix";
    networking.firewall.enable = false;

    services.openssh.enable = false;

    documentation.enable = false;
    documentation.nixos.enable = false;

    # Keep the state version in sync with the nixpkgs release in use.
    system.stateVersion = lib.mkDefault config.system.nixos.release;

    environment.systemPackages = with pkgs; [
      bashInteractive
      cacert
      coreutils-full
      curl
      findutils
      git
      gnugrep
      gnused
      gnutar
      gzip
      iproute2
      iputils
      jq
      less
      man
      openssh
      rsync
      which
      wget
    ];

    # /root/.nix-profile and the default profile are created by the nix
    # activation script; make sure the shell picks them up.
    environment.variables = {
      NIX_REMOTE = lib.mkForce "local";

      # The image ships the nixpkgs source, so <nixpkgs> resolves offline.
      NIX_PATH = lib.mkForce "nixpkgs=${cfg.nixpkgsPath}:/nix/var/nix/profiles/per-user/root/channels:/root/.nix-defexpr/channels";

      EDITOR = "vi";
      PAGER = "less";
    };

    users.users.root.shell = pkgs.bashInteractive;
  };
}
