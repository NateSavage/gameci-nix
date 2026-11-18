# `gameci-checkout`: keep a persistent shallow clone of a large project (with its LFS data) on the
# runner and update it to one commit.
#
# The runner empties its work directory whenever it restarts, so a normal checkout would throw
# away the clone, every LFS object and Unity's Library/ folder. This keeps one clone per repository
# under $GAMECI_CHECKOUTS instead: each run fetches only the commit it needs (depth 1) and only
# the LFS objects not already cached in .git/lfs. Ignored files (Library/, build/) are left alone.
#
# With --target each platform keeps its own Unity Library/. Unity stores one import state per
# platform there, so sharing one folder makes every switch from windows to linux to webgl re-import
# the whole project (tens of minutes). There is still one working tree and one LFS cache; only the
# Library folders are kept apart: the active one is Library/ and the others are parked next to it
# as Library.<platform>. A run for platform T parks the active Library/ under its own name and
# moves Library.T into place (or starts an empty one). Renames within a filesystem are instant.
{
  writeShellApplication,
  git,
  git-lfs,
  coreutils,
  util-linux,
}:
writeShellApplication {
  name = "gameci-checkout";

  runtimeInputs = [
    git
    git-lfs
    coreutils
    util-linux
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: gameci-checkout [--repo OWNER/NAME] [--sha SHA] [--url URL] [--dir DIR] [--target NAME] [--clean-library]

    Defaults come from the GitHub Actions environment: GITHUB_REPOSITORY, GITHUB_SHA and, for
    private repositories, GITHUB_TOKEN. The clone lives in $GAMECI_CHECKOUTS/<name> unless --dir
    is given. Prints the directory; in Actions it is also exported as PROJECT_DIR for later steps.

    --target NAME     the platform about to be built. Its own Unity Library/ is made the active
                      one; the previous platform's is parked as Library.<platform>.
    --clean-library   with --target: throw away that platform's cached Library/ and start empty.
    EOF
    }

    repo="''${GITHUB_REPOSITORY:-}"
    sha="''${GITHUB_SHA:-}"
    url=""
    dir=""
    target=""
    clean_library=0

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="''${2:?--repo needs a value}"; shift 2 ;;
        --sha) sha="''${2:?--sha needs a value}"; shift 2 ;;
        --url) url="''${2:?--url needs a value}"; shift 2 ;;
        --dir) dir="''${2:?--dir needs a value}"; shift 2 ;;
        --target) target="''${2:?--target needs a value}"; shift 2 ;;
        --clean-library) clean_library=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "gameci-checkout: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    case "$target" in *[!A-Za-z0-9_-]*) echo "gameci-checkout: bad --target: $target" >&2; exit 2 ;; esac
    [ "$clean_library" -eq 0 ] || [ -n "$target" ] || { echo "gameci-checkout: --clean-library needs --target" >&2; exit 2; }
    [ -n "$sha" ] || { echo "gameci-checkout: no commit given (--sha or GITHUB_SHA)" >&2; exit 2; }
    if [ -z "$url" ]; then
      [ -n "$repo" ] || { echo "gameci-checkout: no repository given (--repo, --url or GITHUB_REPOSITORY)" >&2; exit 2; }
      url="https://github.com/$repo"
    fi
    if [ -z "$dir" ]; then
      [ -n "$repo" ] || { echo "gameci-checkout: --dir is needed when no repository name is known" >&2; exit 2; }
      : "''${GAMECI_CHECKOUTS:?GAMECI_CHECKOUTS is not set (the gameci module sets it for the runner)}"
      dir="$GAMECI_CHECKOUTS/''${repo#*/}"
    fi

    # --- progress output -------------------------------------------------------------------------
    # git and git-lfs only draw their progress bars on a terminal, and a runner has none, so a long
    # download looks like a hang. These helpers force the progress output on, keep one line per
    # 30 seconds of it (the bars redraw with carriage returns, which would flood the log), and add
    # a heartbeat so even a silent phase shows that something is still running.
    ts() { date '+%H:%M:%S'; }
    log() { echo "[$(ts)] gameci-checkout: $*"; }

    throttle() {
      local line last="" next=0
      # shellcheck disable=SC2162
      # stdbuf: tr buffers about 4 KB when its output is a pipe, and one progress line is a few dozen
      # bytes, so without it nothing came out until the download had finished
      while IFS= read line; do
        # a carriage return followed by a newline makes an empty line: skip it, so that "the last
        # line" below is the last real one
        [ -n "$line" ] || continue
        last="$line"
        if [ "$SECONDS" -ge "$next" ]; then
          echo "    $line"
          next=$((SECONDS + 30))
        fi
      done < <(stdbuf -oL tr '\r' '\n')
      # the final state (100%) is usually swallowed by the throttle
      [ -z "$last" ] || echo "    $last"
    }

    # Size of the LFS store in MB, so a long step can say how much it has fetched. Git LFS keeps
    # finished objects (and the partial one it is working on) there, so it grows while a download runs.
    lfs_store_mb() {
      local common
      common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
      du -sm "$common/lfs" 2>/dev/null | cut -f1
    }

    # step TITLE COMMAND...: a collapsible group in the Actions log, a heartbeat every 30s, and the
    # time the step took.
    step() {
      local title=$1 start=$SECONDS hb rc base_mb
      shift
      echo "::group::$title"
      log "$title"
      base_mb="$(lfs_store_mb)"
      (
        # every 30s: how long it has run and, if the LFS store has grown, how much it has fetched
        # and how fast (git itself prints nothing for long stretches when run without a terminal)
        while sleep 30; do
          elapsed=$((SECONDS - start))
          now_mb="$(lfs_store_mb)"
          grew=""
          if [ -n "$base_mb" ] && [ -n "$now_mb" ] && [ "$now_mb" -gt "$base_mb" ]; then
            grew=", fetched $((now_mb - base_mb)) MB so far ($(( (now_mb - base_mb) / elapsed )) MB/s on average)"
          fi
          log "  ... still working on '$title' (''${elapsed}s so far''${grew})"
        done
      ) &
      hb=$!
      if "$@"; then rc=0; else rc=$?; fi
      kill "$hb" 2>/dev/null || true
      wait "$hb" 2>/dev/null || true
      if [ "$rc" -eq 0 ]; then
        log "done: $title ($((SECONDS - start))s)"
      else
        log "FAILED: $title (exit $rc after $((SECONDS - start))s)"
      fi
      echo "::endgroup::"
      return "$rc"
    }

    do_fetch() { git fetch --progress --depth=1 --no-tags origin "$sha" 2>&1 | throttle; }
    do_lfs() { GIT_LFS_FORCE_PROGRESS=1 git lfs pull 2>&1 | throttle; }
    do_checkout() { git checkout --force --detach FETCH_HEAD; }

    # --- Unity Library per platform -------------------------------------------------------------
    # The platform that owns the active Library/ is recorded in the clone's git directory (Unity may
    # empty Library/, so a marker inside it is not trusted) and also in Library/.gameci-target,
    # which gameci-build reads to warn about a mismatch.
    use_library() {
      local want=$1 state have="" size
      state="$(git rev-parse --path-format=absolute --git-common-dir)/gameci-library-target"
      if [ -d Library ]; then
        if [ -f "$state" ]; then
          have="$(cat "$state")"
        elif [ -f Library/.gameci-target ]; then
          have="$(cat Library/.gameci-target)"
        else
          have="$want"
          log "Library/ has no platform recorded (older layout): keeping it for $want"
        fi
      fi
      if [ "$have" != "$want" ]; then
        if [ -n "$have" ]; then
          [ ! -e "Library.$have" ] || { echo "gameci-checkout: Library.$have already exists next to a Library/ for $have; remove one of them" >&2; exit 1; }
          mv Library "Library.$have"
          log "parked the $have Library as Library.$have"
        fi
        if [ -d "Library.$want" ]; then
          mv "Library.$want" Library
          log "restored the cached $want Library"
        else
          mkdir Library
          log "no cached Library for $want yet: Unity will import the whole project this time"
        fi
      else
        log "Library/ is already the $want one"
      fi
      echo "$want" > "$state"
      echo "$want" > Library/.gameci-target
      for size in Library Library.*; do
        [ -d "$size" ] || continue
        log "  $size: $(du -sh "$size" 2>/dev/null | cut -f1)"
      done
    }

    mkdir -p "$dir"
    cd "$dir"
    [ -d .git ] || git init --quiet
    if git remote get-url origin >/dev/null 2>&1; then
      git remote set-url origin "$url"
    else
      git remote add origin "$url"
    fi

    # Authenticate through the environment (git and git-lfs both read it), so the token is never
    # written to disk. actions/checkout does the equivalent with a config entry.
    if [ -n "''${GITHUB_TOKEN:-}" ] && [[ "$url" == https://github.com/* ]]; then
      b64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
      echo "::add-mask::$b64"
      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
      export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $b64"
    fi

    # Only the commit being built: no history, no tags. LFS content is fetched separately below,
    # so checkout must not download it file by file.
    git lfs install --local --skip-smudge
    log "repository $url, commit $sha, clone in $dir"

    # The parked Library.<platform> folders are untracked and not covered by the project's own
    # .gitignore (which has "Library/"), so tell git to leave them alone: `git clean` below would
    # delete them. This is the clone's own ignore list, not the repository's.
    common="$(git rev-parse --path-format=absolute --git-common-dir)"
    mkdir -p "$common/info"
    touch "$common/info/exclude"
    for pattern in '/Library' '/Library.*'; do
      grep -qxF "$pattern" "$common/info/exclude" || echo "$pattern" >> "$common/info/exclude"
    done

    # One run at a time on this clone: a second one would swap Library folders under the first.
    exec 9>"$common/gameci-checkout.lock"
    if ! flock --nonblock 9; then
      log "another gameci-checkout is using this clone; waiting for it"
      flock 9
    fi
    step "Fetch commit $sha (shallow)" do_fetch
    step "Check out the commit" do_checkout
    # drop untracked files that are not ignored; ignored ones (Library/, build/) stay
    git clean -fd

    if [ -n "$target" ]; then
      echo "::group::Unity Library for $target"
      use_library "$target"
      if [ "$clean_library" -eq 1 ]; then
        log "--clean-library: deleting the cached $target Library (this can take a while)"
        rm -rf Library
        mkdir Library
        echo "$target" > Library/.gameci-target
      fi
      echo "::endgroup::"
    fi

    # Download only the LFS objects that are not in .git/lfs yet, then fill the working tree. Old
    # objects stay cached, so switching between branches is cheap; `git lfs prune` caps the disk
    # use at the price of fetching other branches' objects again.
    lfs_dir="$(git rev-parse --path-format=absolute --git-common-dir)/lfs"
    log "LFS files in this commit: $(git lfs ls-files | wc -l); cache before: $(du -sh "$lfs_dir" 2>/dev/null | cut -f1 || echo 0)"
    step "Download LFS objects not already cached" do_lfs
    log "LFS cache now: $(du -sh "$lfs_dir" 2>/dev/null | cut -f1)"

    # Every file Git LFS tracks should now hold its content. One that is still the small pointer
    # text (version https://git-lfs..., oid, size) is a file the editor cannot import, and the build
    # then fails somewhere far from the cause (an Addressables "unsupported file type" error, say).
    # The usual reason: .gitattributes matches an extension in one case only (*.tga), and Git on
    # Linux matches patterns case-sensitively where Windows does not, so Foo.TGA committed from
    # Windows is a pointer that Linux never replaces. Say so here, with the files, instead.
    # `git lfs ls-files` marks a file whose working-tree content is still the pointer with "-"
    # (and one holding its content with "*").
    pointer_files=()
    while read -r _ marker file; do
      [ "$marker" != "-" ] || pointer_files+=("$file")
    done < <(git lfs ls-files 2>/dev/null)
    if [ "''${#pointer_files[@]}" -gt 0 ]; then
      log "WARNING: ''${#pointer_files[@]} Git LFS file(s) were not replaced by their content"
      printf '  %s\n' "''${pointer_files[@]:0:10}"
      [ "''${#pointer_files[@]}" -le 10 ] || echo "  ... and $(( ''${#pointer_files[@]} - 10 )) more"
      echo "::warning title=Git LFS files are still pointers::''${#pointer_files[@]} file(s) such as ''${pointer_files[0]} are Git LFS pointers, not their content, so Unity cannot import them. Usually .gitattributes matches the extension in one case only: add the other case (for example *.TGA next to *.tga) and commit."
    fi

    echo "$dir"
    if [ -n "''${GITHUB_ENV:-}" ]; then
      echo "PROJECT_DIR=$dir" >> "$GITHUB_ENV"
    fi
  '';

  meta = {
    description = "Persistent shallow clone with an LFS cache, for large Unity projects on a runner";
    mainProgram = "gameci-checkout";
    platforms = [ "x86_64-linux" ];
  };
}
