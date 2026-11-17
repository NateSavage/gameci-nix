# `gameci-test-summary FILE...`: print a short summary of Unity Test Framework (NUnit 3) result
# files, and append it to the GitHub job summary when running in Actions. Always exits 0: whether
# the run passed is decided by `gameci-test`'s exit code, this only reports.
{
  writeShellApplication,
  xmlstarlet,
  coreutils,
}:
writeShellApplication {
  name = "gameci-test-summary";

  runtimeInputs = [
    xmlstarlet
    coreutils
  ];

  text = ''
    if [ $# -eq 0 ]; then
      echo "Usage: gameci-test-summary RESULTS.xml..." >&2
      exit 2
    fi

    # NUnit's root element is <test-run total= passed= failed= skipped= inconclusive= duration= result=>
    attr() { xmlstarlet sel -t -v "/test-run/@$1" "$2" 2>/dev/null || true; }

    emit() {
      printf '%s\n' "$1"
      if [ -n "''${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
      fi
    }

    for file in "$@"; do
      name="$(basename "$file" -results.xml)"
      if [ ! -f "$file" ] || [ "$(attr total "$file")" = "" ]; then
        emit "### Unity $name tests: no results"
        emit ""
        emit "No results file at \`$file\`. The editor probably failed before running the tests (a compile error, a licence problem); see the log."
        emit ""
        continue
      fi

      total="$(attr total "$file")"
      passed="$(attr passed "$file")"
      failed="$(attr failed "$file")"
      skipped="$(attr skipped "$file")"
      inconclusive="$(attr inconclusive "$file")"
      duration="$(attr duration "$file")"
      result="$(attr result "$file")"

      emit "### Unity $name tests: $result"
      emit ""
      emit "$passed passed, $failed failed, $skipped skipped, $inconclusive inconclusive, of $total in ''${duration}s"
      emit ""

      if [ "''${failed:-0}" != "0" ]; then
        emit "Failed:"
        emit ""
        # Failures can be nested in suites; the case's own result is what counts
        xmlstarlet sel -t -m "//test-case[@result='Failed']" -v "@fullname" -n "$file" \
          | head -n 50 \
          | while IFS= read -r test_name; do
              emit "- \`$test_name\`"
            done
        emit ""
      fi
    done
  '';
}
