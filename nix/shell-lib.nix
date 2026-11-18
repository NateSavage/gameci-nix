# Shell code shared by `gameci-build` and `gameci-test`: finding the pinned editor image, loading
# the Unity license from the environment, and sizing the container's memory limit.
#
# Both tools set `prog`, `project`, `unity_version`, `allow_unpinned` and an `extra` array (extra
# arguments for the game-ci CLI) before calling these. The text is spliced into their scripts.
{ imagesJson }:
''
  # On NixOS the setuid newuidmap/newgidmap that rootless Podman needs live in /run/wrappers/bin,
  # which a systemd service's PATH does not include.
  export PATH="/run/wrappers/bin:$PATH"

  images_json=${imagesJson}

  die() {
    echo "$prog: $*" >&2
    exit 2
  }

  check_project() {
    [ -d "$project/ProjectSettings" ] || die "'$project' is not a Unity project (no ProjectSettings/)"
  }

  # Sets unity_version from ProjectVersion.txt unless it was given.
  detect_version() {
    if [ -z "$unity_version" ]; then
      unity_version="$(sed -n 's/^m_EditorVersion: *//p' "$project/ProjectSettings/ProjectVersion.txt" | head -n1 | tr -d '\r')"
    fi
    [ -n "$unity_version" ] || die "could not determine the Unity version; pass --unity"
  }

  # resolve_image TARGET: sets `image` to the pinned image for unity_version and TARGET.
  resolve_image() {
    local target=$1 module repository digest tag
    module="$(jq -r --arg t "$target" '.targets[$t].module // empty' "$images_json")"
    [ -n "$module" ] || die "unknown target '$target' (expected: $(jq -r '.targets | keys | join(", ")' "$images_json"))"

    repository="$(jq -r '.repository' "$images_json")"
    digest="$(jq -r --arg v "$unity_version" --arg t "$target" '.versions[$v][$t] // empty' "$images_json")"
    if [ -n "$digest" ]; then
      image="$repository@$digest"
    elif [ "$allow_unpinned" -eq 1 ]; then
      tag="ubuntu-$unity_version-$module-$(jq -r '.imageVersion' "$images_json")"
      image="$repository:$tag"
      echo "$prog: WARNING: no pinned image for $unity_version/$target, using unpinned $image" >&2
    else
      echo "$prog: no pinned image for Unity $unity_version / $target." >&2
      echo "  pinned versions:" >&2
      jq -r '.versions | keys[] | "    " + .' "$images_json" >&2
      echo "  Add it with 'nix run .#update-images -- $unity_version', or pass --allow-unpinned." >&2
      exit 1
    fi
  }

  # The Unity license comes from the environment, never from the command line.
  load_license() {
    if [ -n "''${GAMECI_ENV_FILE:-}" ]; then
      set -a
      # shellcheck disable=SC1090
      . "$GAMECI_ENV_FILE"
      set +a
    fi
    if [ -n "''${GAMECI_LICENSE_FILE:-}" ]; then
      UNITY_LICENSE="$(cat "$GAMECI_LICENSE_FILE")"
      export UNITY_LICENSE
    fi
  }

  # The CLI defaults the container's memory limit to 95% of the host's RAM. Inside a service with
  # MemoryMax that is more than the unit may use, so the run would be killed rather than fail
  # cleanly. Unless the caller chose a limit, take 90% of this cgroup's limit (if it has one).
  default_memory_limit() {
    local a cgroup limit
    for a in "''${extra[@]}"; do
      case "$a" in
        --dockerMemoryLimit|--dockerMemoryLimit=*|--docker-memory-limit|--docker-memory-limit=*) return 0 ;;
        *) ;;
      esac
    done
    cgroup="$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null || true)"
    limit="$(cat "/sys/fs/cgroup$cgroup/memory.max" 2>/dev/null || true)"
    if [[ "$limit" =~ ^[0-9]+$ ]]; then
      extra+=(--dockerMemoryLimit "$(( limit * 9 / 10 / 1048576 ))m")
    fi
  }

  # Cancelling a job. The runner stops a cancelled step by signalling its processes, but the Podman
  # container is detached from them and would keep running: still importing and holding the Unity
  # licence seat, with nobody reading its output. Every container the CLI starts carries the label
  # gameci.run=$GAMECI_RUN_ID (the `docker` shim in docker-shim.nix adds it), and run_cancellable
  # stops the ones belonging to this run when it gets SIGINT or SIGTERM.
  GAMECI_RUN_ID="$$-$SECONDS-$RANDOM"
  export GAMECI_RUN_ID

  # (shellcheck cannot see that cancel_containers is called from a trap)
  # shellcheck disable=SC2329
  run_container_ids() {
    podman ps -q --filter "label=gameci.run=$GAMECI_RUN_ID" 2>/dev/null || true
  }

  # Asks the Unity editor in each of this run's containers to quit, so the container's own script
  # carries on and returns the licence seat, then waits for the containers to be gone. The runner only
  # gives a cancelled step a few seconds, so the first thing done is the signal; the wait (and the
  # forced stop after it) only matter if this process is still alive. A container that does not quit
  # in time is stopped, which cannot return the seat.
  # shellcheck disable=SC2329
  cancel_containers() {
    local ids=() id waited=0
    mapfile -t ids < <(run_container_ids)
    [ "''${#ids[@]}" -gt 0 ] || return 0
    echo "$prog: cancelled: asking Unity in the container to quit so that it returns the licence seat" >&2
    for id in "''${ids[@]}"; do
      podman exec "$id" pkill -TERM -f '^/opt/unity/Editor/Unity ' >/dev/null 2>&1 || true
    done
    while [ "$waited" -lt 180 ] && [ -n "$(run_container_ids)" ]; do
      sleep 2
      waited=$((waited + 2))
    done
    mapfile -t ids < <(run_container_ids)
    if [ "''${#ids[@]}" -gt 0 ]; then
      echo "$prog: the container did not quit in time, stopping it (the licence seat may not have been returned)" >&2
      podman stop --time 10 "''${ids[@]}" >/dev/null 2>&1 || true
    fi
  }

  # run_cancellable COMMAND...: runs COMMAND and returns its exit code. The command runs in the
  # background so that a signal is handled at once (a shell only runs its trap after a foreground
  # command ends); on SIGINT or SIGTERM the containers of this run are told to quit, and the command
  # is then waited for.
  run_cancellable() {
    local child code=0 signalled=0
    trap 'signalled=1; cancel_containers' INT TERM
    "$@" &
    child=$!
    # a signal ends a wait early, with a status of its own: wait again for the command's real one
    while :; do
      signalled=0
      wait "$child" && code=0 || code=$?
      [ "$signalled" -eq 1 ] || break
    done
    trap - INT TERM
    return "$code"
  }

  # ensure_image NEXT_STAGE: make sure the pinned editor image is in local storage, pulling it if
  # not. The Unity editor image is several GB, and the wait for it before a version's first run is
  # the longest of the whole build, so a pull is a stage of its own: the [CI] markers are turned
  # into a log section and a line in the run summary by gameci-stages. When the image is already
  # there only one line is printed. The CLI would pull it anyway, silently inside `docker run`;
  # doing it here means that run finds it ready. NEXT_STAGE names the stage that starts after
  # (the editor start-up, licence activation and project import).
  ensure_image() {
    local next=$1 start took
    if podman image exists "$image" 2>/dev/null; then
      echo "$prog: editor image already present" >&2
    else
      echo "[CI] stage start Image"
      echo "$prog: pulling the editor image $image" >&2
      start=$SECONDS
      podman pull "$image" >&2
      took=$((SECONDS - start))
      echo "[CI] stage end Image $((took / 60))m$(printf '%02d' $((took % 60)))s"
    fi
    echo "[CI] stage start $next"
  }
''
