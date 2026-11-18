# NixOS module: everything a host needs to run Game CI Unity builds with rootless Podman, and an
# optional self-hosted GitHub Actions runner that does the building.
#
# Use as `inputs.gameci.nixosModules.default`.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.gameci;
  r = cfg.runner;
  system = pkgs.stdenv.hostPlatform.system;

  # The nixpkgs github-runner module sandboxes the runner so tightly that rootless Podman cannot
  # start. Each of these is needed (found by running Podman under a transient systemd unit with the
  # runner's settings and relaxing one thing at a time):
  #
  #   NoNewPrivileges
  #     newuidmap/newgidmap are setuid-root, so the process must be allowed to gain privileges
  #   PrivateUsers, RestrictNamespaces
  #     Podman creates a user namespace and maps the subuid range into it
  #   CapabilityBoundingSet
  #     only the setuid helper ever holds these; the runner process itself has none. Writing the
  #     uid map needs CAP_SETUID/CAP_SETGID, CAP_SYS_ADMIN (checked by the kernel against the file
  #     opener) and CAP_DAC_OVERRIDE (the map file belongs to the unprivileged user)
  #   ProtectProc = default
  #     with "invisible" newuidmap cannot see the process it is mapping
  #   PrivateDevices
  #     rootless networking (pasta) opens /dev/net/tun
  #   ProtectHostname
  #     the container runtime calls sethostname inside the container
  #   SystemCallFilter
  #     the module denies @mount, capset, sethostname and setdomainname. Podman needs mount (the
  #     overlay storage and the container's own filesystems), sethostname (the container's
  #     hostname), and capset: denying it makes systemd turn on no_new_privs whatever
  #     NoNewPrivileges says, which stops the setuid newuidmap from working ("write to uid_map
  #     failed: Operation not permitted"). The rest of the module's filter is kept.
  #   ProtectKernelTunables, ProtectKernelLogs
  #     they bind-mount over parts of /proc (/proc/sys, /proc/kmsg, ...). A newer kernel (6.18;
  #     6.6 did not mind) then refuses the container's own mount of /proc: "crun: mount `proc` to
  #     `proc`: Operation not permitted". Either one alone is enough to break it. Found by
  #     scripts/probe-runner-unit.sh, which tries the real unit with settings removed.
  #   RestrictSUIDSGID
  #     unpacking an image layer creates setuid files (/usr/bin/chage and friends in the Unity
  #     image), and this option makes chmod with a setuid bit fail: "unpacking failed ... open
  #     /usr/bin/chage: operation not permitted". The files only live inside the user namespace.
  #
  # Everything else stays as the module sets it: read-only system, kernel/cgroup protections and
  # address-family limits. All of it was tested with a real container under a transient unit.
  podmanOverrides = {
    NoNewPrivileges = false;
    PrivateUsers = false;
    RestrictNamespaces = false;
    PrivateDevices = false;
    ProtectHostname = false;
    ProtectProc = "default";
    RestrictSUIDSGID = false;
    ProtectKernelTunables = false;
    ProtectKernelLogs = false;
    SystemCallFilter = lib.mkForce [
      "~@clock"
      "~@cpu-emulation"
      "~@module"
      "~@obsolete"
      "~@raw-io"
      "~@reboot"
    ];
    CapabilityBoundingSet = [
      "CAP_SETUID"
      "CAP_SETGID"
      "CAP_SYS_ADMIN"
      "CAP_DAC_OVERRIDE"
    ];
    # Podman wants a private XDG_RUNTIME_DIR
    RuntimeDirectoryMode = "0700";
    # build output must be group-readable so other services (a file portal) can serve it
    UMask = "0002";
  };

  serviceOverrides =
    podmanOverrides
    // r.serviceOverrides
    // {
      ReadWritePaths = [ cfg.stateDir ] ++ r.writablePaths ++ (r.serviceOverrides.ReadWritePaths or [ ]);
    };
in
{
  options.services.gameci = {
    enable = mkEnableOption "Game CI Unity builds with rootless Podman";

    package = mkOption {
      type = types.package;
      default = self.packages.${system}.gameci;
      defaultText = "gameci-nix's gameci";
      description = ''
        The tools jobs call: `gameci-build`, `gameci-test`, `gameci-test-summary` and
        `gameci-checkout`. Also installed system-wide for manual runs.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "gameci";
      description = ''
        System user (and group) that runs builds. It needs a real account, not a dynamic one,
        because rootless Podman requires subuid/subgid ranges.
      '';
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra groups for the build user, e.g. the group that owns the output directory.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/gameci";
      description = ''
        Home of the build user. Holds `home/` (HOME, mounted into the build container as /root),
        `data/` (Podman's image storage, kept out of HOME so it is not exposed to the container),
        `checkouts/` (persistent project clones, see `GAMECI_CHECKOUTS`) and `work/` (the runner's
        work directory, emptied by the runner on every start). Unity editor images and projects
        with their `Library/` and LFS data are large, so this should be on a roomy disk.
      '';
    };

    runner = {
      enable = mkEnableOption "a GitHub Actions runner for Unity builds";

      name = mkOption {
        type = types.str;
        default = "unity";
        description = "Attribute name under `services.github-runners` (the unit is `github-runner-<name>`).";
      };

      githubName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name GitHub knows the runner by. Defaults to the machine's hostname.";
      };

      url = mkOption {
        type = types.str;
        example = "https://github.com/my-org";
        description = "Repository or organization the runner registers with.";
      };

      tokenFile = mkOption {
        type = types.path;
        description = "File containing a runner registration token (or PAT).";
      };

      unityEnvFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          A `KEY=value` file with the Unity license credentials (`UNITY_EMAIL`, `UNITY_PASSWORD`,
          optionally `UNITY_SERIAL`). Must be readable by the build user. Exposed to jobs as
          `GAMECI_ENV_FILE`, which `gameci-build` reads. Anything running on this runner can read it.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.github-runner;
        defaultText = "pkgs.github-runner";
        description = "The GitHub Actions runner package.";
      };

      extraLabels = mkOption {
        type = types.listOf types.str;
        default = [
          "nixos"
          "unity"
        ];
        description = "Labels jobs select this runner with (`runs-on: [self-hosted, unity]`).";
      };

      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Extra packages on the runner's PATH. `gameci-build` and `git-lfs` are always included.";
      };

      extraEnvironment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Extra environment variables for the runner (and so its jobs).";
      };

      writablePaths = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Paths outside the state directory that jobs may write to, e.g. a build output directory.";
      };

      serviceOverrides = mkOption {
        type = types.attrs;
        default = { };
        example = lib.literalExpression "import ../platform/runner-sandbox.nix";
        description = ''
          systemd settings applied on top of the Podman requirements above, for resource limits
          and network restrictions. Entries here win over the module's own, except
          `ReadWritePaths`, which is added to.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    virtualisation.podman.enable = true;

    users.groups.${cfg.user} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.stateDir;
      extraGroups = cfg.extraGroups;
      autoSubUidGidRange = true;
    };

    systemd.tmpfiles.rules = map (d: "d ${d} 0750 ${cfg.user} ${cfg.user} -") [
      cfg.stateDir
      "${cfg.stateDir}/home"
      "${cfg.stateDir}/data"
      "${cfg.stateDir}/checkouts"
      "${cfg.stateDir}/work"
    ];

    environment.systemPackages = [ cfg.package ];

    services.github-runners = mkIf r.enable {
      ${r.name} = {
        enable = true;
        inherit (r) url tokenFile package extraLabels;
        name = r.githubName;
        user = cfg.user;
        group = cfg.user;
        # The runner empties its work directory on every start, so nothing that must persist
        # (HOME, Podman's image storage) can live there.
        workDir = "${cfg.stateDir}/work";
        extraPackages = [
          cfg.package
          pkgs.git-lfs
        ]
        ++ r.extraPackages;
        extraEnvironment = {
          HOME = "${cfg.stateDir}/home";
          XDG_DATA_HOME = "${cfg.stateDir}/data";
          XDG_RUNTIME_DIR = "/run/github-runner/${r.name}";
          # Where jobs keep persistent clones of large projects. The runner empties its work
          # directory on every start, which would throw away Unity's Library/ and all LFS data.
          GAMECI_CHECKOUTS = "${cfg.stateDir}/checkouts";
          FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 = "true";
        }
        // lib.optionalAttrs (r.unityEnvFile != null) { GAMECI_ENV_FILE = toString r.unityEnvFile; }
        // r.extraEnvironment;
        inherit serviceOverrides;
      };
    };
  };
}
