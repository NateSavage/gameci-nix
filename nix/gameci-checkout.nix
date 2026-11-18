# `gameci-checkout`: keep a persistent shallow clone of a large project (with its LFS data) on the
# runner and update it to one commit.
#
# The runner empties its work directory whenever it restarts, so a normal checkout would throw
# away the clone, every LFS object and Unity's Library/ folder. This keeps one clone per repository
# under $GAMECI_CHECKOUTS instead: each run fetches only the commit it needs (depth 1) and only
# the LFS objects not already cached in .git/lfs. Ignored files (Library/, build/) are left alone.
{
  writeShellApplication,
  git,
  git-lfs,
  coreutils,
}:
writeShellApplication {
  name = "gameci-checkout";

  runtimeInputs = [
    git
    git-lfs
    coreutils
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: gameci-checkout [--repo OWNER/NAME] [--sha SHA] [--url URL] [--dir DIR]

    Defaults come from the GitHub Actions environment: GITHUB_REPOSITORY, GITHUB_SHA and, for
    private repositories, GITHUB_TOKEN. The clone lives in $GAMECI_CHECKOUTS/<name> unless --dir
    is given. Prints the directory; in Actions it is also exported as PROJECT_DIR for later steps.
    EOF
    }

    repo="''${GITHUB_REPOSITORY:-}"
    sha="''${GITHUB_SHA:-}"
    url=""
    dir=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="''${2:?--repo needs a value}"; shift 2 ;;
        --sha) sha="''${2:?--sha needs a value}"; shift 2 ;;
        --url) url="''${2:?--url needs a value}"; shift 2 ;;
        --dir) dir="''${2:?--dir needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "gameci-checkout: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

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
      while IFS= read line; do
        last="$line"
        if [ "$SECONDS" -ge "$next" ]; then
          echo "    $line"
          next=$((SECONDS + 30))
        fi
      done < <(tr '\r' '\n')
      # the final state (100%) is usually swallowed by the throttle
      [ -z "$last" ] || echo "    $last"
    }

    # step TITLE COMMAND...: a collapsible group in the Actions log, a heartbeat every 30s, and the
    # time the step took.
    step() {
      local title=$1 start=$SECONDS hb rc
      shift
      echo "::group::$title"
      log "$title"
      (
        while sleep 30; do
          log "  ... still working on '$title' ($((SECONDS - start))s so far, .git is $(du -sh .git 2>/dev/null | cut -f1))"
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
    step "Fetch commit $sha (shallow)" do_fetch
    step "Check out the commit" do_checkout
    # drop untracked files that are not ignored; ignored ones (Library/, build/) stay
    git clean -fd

    # Download only the LFS objects that are not in .git/lfs yet, then fill the working tree. Old
    # objects stay cached, so switching between branches is cheap; `git lfs prune` caps the disk
    # use at the price of fetching other branches' objects again.
    # how much is left to download, so a long step has a size attached to it
    log "LFS files in this commit: $(git lfs ls-files | wc -l); cache before: $(du -sh .git/lfs 2>/dev/null | cut -f1 || echo 0)"
    step "Download LFS objects not already cached" do_lfs
    log "LFS cache now: $(du -sh .git/lfs 2>/dev/null | cut -f1)"

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
