# `gameci-test`: run Unity Test Framework tests through the game-ci CLI with a pinned editor image
# and Podman. Edit mode by default.
#
# The tests run in the same Linux editor image as a Linux build, with the same Unity login. The
# CLI writes NUnit result XML and the editor log to the artifacts directory.
{
  writeShellApplication,
  podman,
  runCommand,
  jq,
  coreutils,
  gnused,
  game-ci-cli,
  gameci-test-summary,
  imagesJson,
}:
let
  dockerShim = runCommand "podman-as-docker" { } ''
    mkdir -p $out/bin
    ln -s ${podman}/bin/podman $out/bin/docker
  '';
in
writeShellApplication {
  name = "gameci-test";

  runtimeInputs = [
    game-ci-cli
    gameci-test-summary
    podman
    dockerShim
    jq
    coreutils
    gnused
  ];

  text = ''
    prog=gameci-test
    ${import ./shell-lib.nix { inherit imagesJson; }}

    usage() {
      cat <<'EOF'
    Usage: gameci-test [options] [-- extra game-ci args]

    Runs Unity Test Framework tests in a pinned editor container. Exits non-zero if any test fails
    or the editor cannot run them, and prints a summary (also added to the GitHub job summary).

    Options:
      --project DIR       Unity project directory (default: .)
      --unity VERSION     editor version (default: read from ProjectSettings/ProjectVersion.txt)
      --platforms LIST    editmode (default), playmode, or both separated by ";".
                          Play mode is passed through but has not been tried here.
      --filter EXPR       only run tests matching this Unity -testFilter expression (no spaces)
      --assemblies LIST   only run these test assemblies, separated by ";"
      --coverage          turn on code coverage (off by default: it crashes some editor versions)
      --artifacts DIR     where result XML and logs go, relative to the project (default: artifacts)
      --allow-unpinned    if the version has no pinned image, use the rolling tag instead of failing
      -h, --help          this help

    Results: <artifacts>/<platform>-results.xml (NUnit) and <artifacts>/<platform>.log.

    License (read from the environment, never from the command line):
      GAMECI_ENV_FILE       path to a KEY=value file with UNITY_EMAIL / UNITY_PASSWORD / UNITY_SERIAL
      GAMECI_LICENSE_FILE   path to a Unity .ulf license file
    EOF
    }

    project="."
    unity_version=""
    platforms="editmode"
    filter=""
    assemblies=""
    coverage=false
    artifacts="artifacts"
    allow_unpinned=0
    extra=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --project) project="''${2:?--project needs a value}"; shift 2 ;;
        --unity) unity_version="''${2:?--unity needs a value}"; shift 2 ;;
        --platforms) platforms="''${2:?--platforms needs a value}"; shift 2 ;;
        --filter) filter="''${2:?--filter needs a value}"; shift 2 ;;
        --assemblies) assemblies="''${2:?--assemblies needs a value}"; shift 2 ;;
        --coverage) coverage=true; shift ;;
        --artifacts) artifacts="''${2:?--artifacts needs a value}"; shift 2 ;;
        --allow-unpinned) allow_unpinned=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; extra=("$@"); break ;;
        *) echo "$prog: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    # accept "editmode,playmode" as well as the CLI's "editmode;playmode"
    platforms="''${platforms//,/;}"

    check_project
    detect_version
    # tests run in the Linux editor image, like a Linux build
    resolve_image linux
    load_license
    default_memory_limit

    # Extra editor arguments are passed to the CLI as one space-separated string. The "=" form is
    # needed: the value starts with "-", and without it the CLI's argument parser splits it into
    # single-letter flags.
    params=()
    [ -z "$filter" ] || params+=(-testFilter "$filter")
    [ -z "$assemblies" ] || params+=(-assemblyNames "$assemblies")
    if [ "''${#params[@]}" -gt 0 ]; then
      extra+=("--customParameters=''${params[*]}")
    fi

    echo "$prog: Unity $unity_version, platforms $platforms, image $image" >&2
    ensure_image Tests

    # The CLI mounts its working directory into the container, so it has to run in the project.
    cd "$project"
    code=0
    game-ci test --docker \
      --customImage "$image" \
      --testPlatforms "$platforms" \
      --artifactsPath "$artifacts" \
      --coverageEnabled="$coverage" \
      "''${extra[@]}" || code=$?

    results=()
    for platform in ''${platforms//;/ }; do
      case "$platform" in
        editmode|playmode|standalone) results+=("$artifacts/$platform-results.xml") ;;
        *) ;;
      esac
    done
    if [ "''${#results[@]}" -gt 0 ]; then
      gameci-test-summary "''${results[@]}"
    fi

    # The CLI exits 0 when every test passed and 2 when some failed (results exist for both). Any
    # other code means the run itself broke (the editor, the container, the licence) before it could
    # report, which is not a test failure and needs a different kind of attention.
    case "$code" in
      0|2) ;;
      *) echo "::error::The Unity test run itself failed (exit code $code): the editor or the container broke before the tests could report, so this is not a test failure. See the log above." ;;
    esac

    exit "$code"
  '';

  meta = {
    description = "Run Unity tests via the game-ci CLI with pinned editor images and Podman";
    mainProgram = "gameci-test";
    platforms = [ "x86_64-linux" ];
  };
}
