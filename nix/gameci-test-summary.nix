# `gameci-test-summary FILE...`: print a short summary of Unity Test Framework (NUnit 3) result
# files, and append it to the GitHub job summary when running in Actions. Always exits 0: whether
# the run passed is decided by `gameci-test`'s exit code, this only reports.
#
# Each failed test is also printed as a `::error file=...,line=...,title=...::message` annotation, with
# the file and line of the first stack frame in the project's own Assets/ or Packages/ code, so
# failures show on the run page and on the test's line in the commit. GitHub shows at most ten error
# annotations per step, so only the first ten (GAMECI_MAX_ANNOTATIONS) are made; the summary lists more.
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

    # Failed tests as GitHub annotations, so they show on the run page and on the line of the test
    # in the commit, not only in the summary. GitHub shows at most ten error annotations per step,
    # so the budget is shared by all result files; the rest are in the summary list.
    annotations_left="''${GAMECI_MAX_ANNOTATIONS:-10}"

    # what a workflow command needs percent-encoded: the message, and also : and , in properties
    esc_data() {
      local s=$1
      s=''${s//'%'/%25}
      s=''${s//$'\r'/%0D}
      s=''${s//$'\n'/%0A}
      printf '%s' "$s"
    }
    esc_prop() {
      local s
      s="$(esc_data "$1")"
      s=''${s//:/%3A}
      s=''${s//,/%2C}
      printf '%s' "$s"
    }

    annotate_failures() {
      local file=$1 count i name message stack loc path line failed_case
      count="$(xmlstarlet sel -t -v "count(//test-case[@result='Failed'])" "$file" 2>/dev/null || true)"
      count="''${count:-0}"
      for ((i = 1; i <= count; i++)); do
        if [ "$annotations_left" -le 0 ]; then
          printf '::notice::%s\n' "$((count - i + 1)) more failed tests in $(basename "$file") are not annotated (GitHub shows ten per step); see the run summary."
          return 0
        fi
        failed_case="(//test-case[@result='Failed'])[$i]"
        name="$(xmlstarlet sel -t -v "$failed_case/@fullname" "$file" 2>/dev/null || true)"
        message="$(xmlstarlet sel -t -v "$failed_case/failure/message" "$file" 2>/dev/null || true)"
        [ -n "$message" ] || message="$(xmlstarlet sel -t -v "$failed_case/reason/message" "$file" 2>/dev/null || true)"
        message="$(printf '%s' "$message" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$message" ] || message="the test failed"
        stack="$(xmlstarlet sel -t -v "$failed_case/failure/stack-trace" "$file" 2>/dev/null || true)"
        # the first frame in the project's own code: ".../Assets/Foo/FooTests.cs:42"
        loc="$(printf '%s\n' "$stack" | grep -oE '(Assets|Packages)/[^:() ]+\.cs:[0-9]+' | head -n 1 || true)"
        if [ -n "$loc" ]; then
          path="''${loc%:*}"
          line="''${loc##*:}"
          printf '::error file=%s,line=%s,title=%s::%s\n' "$(esc_prop "$path")" "$line" "$(esc_prop "$name")" "$(esc_data "$message")"
        else
          printf '::error title=%s::%s\n' "$(esc_prop "$name")" "$(esc_data "$message")"
        fi
        annotations_left=$((annotations_left - 1))
      done
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
        annotate_failures "$file"
      fi
    done
  '';
}
