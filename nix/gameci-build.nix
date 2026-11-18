# `gameci-build`: run a Unity build through the game-ci CLI with a pinned editor image and Podman.
#
# The CLI hard-codes `docker run`, so a `docker` symlink to Podman is put on its PATH.
# The host still needs Podman set up (rootless: newuidmap/newgidmap wrappers, subuid ranges and
# /etc/containers/policy.json). On NixOS, `virtualisation.podman.enable = true` does that.
{
  writeShellApplication,
  podman,
  runCommand,
  jq,
  coreutils,
  gnused,
  game-ci-cli,
  imagesJson,
}:
let
  dockerShim = runCommand "podman-as-docker" { } ''
    mkdir -p $out/bin
    ln -s ${podman}/bin/podman $out/bin/docker
  '';
in
writeShellApplication {
  name = "gameci-build";

  runtimeInputs = [
    game-ci-cli
    podman
    dockerShim
    jq
    coreutils
    gnused
  ];

  text = ''
    prog=gameci-build
    ${import ./shell-lib.nix { inherit imagesJson; }}

    usage() {
      cat <<'EOF'
    Usage: gameci-build --target <linux|windows|webgl|android> [options] [-- extra game-ci args]

    Options:
      --target T          build target (required)
      --project DIR       Unity project directory (default: .)
      --out DIR           output directory, relative to the project (default: build)
      --unity VERSION     editor version (default: read from ProjectSettings/ProjectVersion.txt)
      --allow-unpinned    if the version has no pinned image, use the rolling tag instead of failing
      --list              print the pinned versions and targets, then exit
      -h, --help          this help

    License (read from the environment, never from the command line):
      GAMECI_LICENSE_FILE   path to a Unity .ulf license file (exported as UNITY_LICENSE)
      GAMECI_ENV_FILE       path to a KEY=value file with UNITY_EMAIL / UNITY_PASSWORD / UNITY_SERIAL
      UNITY_LICENSE, UNITY_EMAIL, UNITY_PASSWORD, UNITY_SERIAL are also honoured directly.
    EOF
    }

    target=""
    project="."
    out="build"
    unity_version=""
    allow_unpinned=0
    extra=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --target) target="''${2:?--target needs a value}"; shift 2 ;;
        --project) project="''${2:?--project needs a value}"; shift 2 ;;
        --out) out="''${2:?--out needs a value}"; shift 2 ;;
        --unity) unity_version="''${2:?--unity needs a value}"; shift 2 ;;
        --allow-unpinned) allow_unpinned=1; shift ;;
        --list)
          jq -r '.versions | to_entries[] | "\(.key): \(.value | keys | join(", "))"' "$images_json"
          exit 0
          ;;
        -h|--help) usage; exit 0 ;;
        --) shift; extra=("$@"); break ;;
        *) echo "$prog: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    [ -n "$target" ] || { echo "$prog: --target is required" >&2; usage >&2; exit 2; }

    platform="$(jq -r --arg t "$target" '.targets[$t].platform // empty' "$images_json")"
    check_project
    detect_version
    resolve_image "$target"
    load_license
    default_memory_limit

    echo "$prog: Unity $unity_version, target $target, image $image" >&2

    # By default the CLI derives a version number from git history (strategy "Semantic"), which
    # runs `git fetch --unshallow` and needs network access and credentials the build does not
    # have (and defeats the shallow clone). Turn that off unless the caller chooses a strategy.
    versioning=(--versioningStrategy None)
    for a in "''${extra[@]}"; do
      case "$a" in --versioningStrategy|--versioningStrategy=*) versioning=() ;; esac
    done

    # The CLI mounts its working directory into the container, so it has to run in the project.
    cd "$project"
    exec game-ci build \
      --targetPlatform "$platform" \
      --customImage "$image" \
      --buildsPath "$out" \
      "''${versioning[@]}" \
      "''${extra[@]}"
  '';

  meta = {
    description = "Run Unity builds via the game-ci CLI with pinned editor images and Podman";
    mainProgram = "gameci-build";
    platforms = [ "x86_64-linux" ];
  };
}
