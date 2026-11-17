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
    git fetch --depth=1 --no-tags origin "$sha"
    git checkout --force --detach FETCH_HEAD
    # drop untracked files that are not ignored; ignored ones (Library/, build/) stay
    git clean -fd

    # Download only the LFS objects that are not in .git/lfs yet, then fill the working tree. Old
    # objects stay cached, so switching between branches is cheap; `git lfs prune` caps the disk
    # use at the price of fetching other branches' objects again.
    git lfs pull

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
