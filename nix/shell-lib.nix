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
''
