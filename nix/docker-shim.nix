# A `docker` command for the game-ci CLI, which hard-codes `docker run`, that is Podman. Every
# container the CLI starts is labelled gameci.run=$GAMECI_RUN_ID (set by shell-lib.nix), so the
# wrapper that started it can find and stop it again when the job is cancelled.
{ writeShellScriptBin, podman }:
writeShellScriptBin "docker" ''
  if [ "''${1:-}" = run ] && [ -n "''${GAMECI_RUN_ID:-}" ]; then
    shift
    exec ${podman}/bin/podman run --label "gameci.run=$GAMECI_RUN_ID" "$@"
  fi
  exec ${podman}/bin/podman "$@"
''
