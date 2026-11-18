# `gameci-library`: tell whether a Unity project's cached Library/ is up to date for the commit that
# is checked out, so a workflow can skip an import it does not need.
#
# Unity keeps its whole import state in Library/ (one per platform on a runner, see
# gameci-checkout --target). After a Unity run succeeds the workflow calls `gameci-library mark`,
# which records a fingerprint of everything that decides what the import looks like:
#
#   - the editor version (ProjectSettings/ProjectVersion.txt)
#   - the platform the Library belongs to (Library/.gameci-target)
#   - the git tree ids of Assets/, Packages/ and ProjectSettings/ at the checked-out commit
#
# `gameci-library status` compares the current fingerprint with that record. The record lives in
# Library/ itself, so it disappears with the Library (a clean, a deletion, a different platform's
# folder parked away), and a build that failed before it finished never writes one.
#
# This is a shortcut for a separate import step, not a guarantee: Unity still reconciles the
# Library every time the editor starts, so a wrong answer can only cost time, never a wrong build.
{
  writeShellApplication,
  git,
  coreutils,
  gnused,
}:
writeShellApplication {
  name = "gameci-library";

  runtimeInputs = [
    git
    coreutils
    gnused
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: gameci-library <status|mark|fingerprint> [--project DIR]

      status        exit 0 and print "up to date" if the cached Library/ was imported from this
                    commit's Assets/, Packages/ and ProjectSettings/; otherwise exit 1 and print why.
                    In GitHub Actions it also sets LIBRARY_UP_TO_DATE=true|false for later steps.
      mark          record that the Library/ is now up to date for this commit (call it after a
                    Unity run that finished successfully)
      fingerprint   print the fingerprint

    --project DIR   the Unity project (default: the current directory)
    EOF
    }

    command="''${1:-}"
    [ $# -eq 0 ] || shift
    project="."
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) project="''${2:?--project needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "gameci-library: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done
    case "$command" in status|mark|fingerprint) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac

    cd "$project"
    stamp=Library/.gameci-import-stamp

    fingerprint() {
      local unity target trees
      unity="$(sed -n 's/^m_EditorVersion: *//p' ProjectSettings/ProjectVersion.txt 2>/dev/null | head -n1 | tr -d '\r')"
      target="$(cat Library/.gameci-target 2>/dev/null || echo none)"
      # tree ids change exactly when something below the folder changes (LFS files count by their
      # pointer, which names the content)
      trees="$(git rev-parse HEAD:Assets HEAD:Packages HEAD:ProjectSettings 2>/dev/null | tr '\n' ' ' || true)"
      [ -n "$trees" ] || return 1
      printf 'unity=%s target=%s trees=%s\n' "$unity" "$target" "$trees" | sha256sum | cut -d' ' -f1
    }

    set_env() {
      [ -z "''${GITHUB_ENV:-}" ] || echo "LIBRARY_UP_TO_DATE=$1" >> "$GITHUB_ENV"
    }

    case "$command" in
      fingerprint)
        fingerprint || { echo "gameci-library: not a git checkout of a Unity project" >&2; exit 1; }
        ;;

      mark)
        [ -d Library ] || { echo "gameci-library: no Library/ to mark" >&2; exit 0; }
        if now="$(fingerprint)"; then
          echo "$now" > "$stamp"
          echo "gameci-library: Library/ marked up to date for this commit"
        else
          echo "gameci-library: not a git checkout, nothing to mark" >&2
        fi
        ;;

      status)
        if [ ! -d Library ]; then
          echo "not up to date: there is no Library/ yet"; set_env false; exit 1
        elif [ ! -f "$stamp" ]; then
          echo "not up to date: the Library/ has not been marked as imported"; set_env false; exit 1
        elif ! now="$(fingerprint)"; then
          echo "not up to date: cannot tell (not a git checkout)"; set_env false; exit 1
        elif [ "$(cat "$stamp")" != "$now" ]; then
          echo "not up to date: Assets/, Packages/, ProjectSettings/, the editor version or the platform changed since the last import"
          set_env false; exit 1
        else
          echo "up to date"; set_env true
        fi
        ;;
    esac
  '';

  meta = {
    description = "Check whether a Unity project's cached Library/ is up to date for the checked-out commit";
    mainProgram = "gameci-library";
    platforms = [ "x86_64-linux" ];
  };
}
