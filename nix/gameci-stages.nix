# `gameci-stages`: a filter for a Unity build's log that makes its stages visible in GitHub Actions.
#
#   gameci-build ... 2>&1 | gameci-stages
#
# One Unity run does several things in a row (import the project, build Addressables, build the
# player), and a step in GitHub's UI can only be one thing. This reads the log as it streams and
# turns the stage markers the build method prints into collapsible log groups, and into timing lines
# for the run summary:
#
#   [CI] stage start <Name>             closes the open group and opens one called <Name>
#   [CI] stage end <Name> <duration>    closes the group and records "<Name>: <duration>"
#
# The part of the log before the first marker (editor start-up and project import) is the first
# group. Everything else passes through unchanged and live. Game CI indents Unity's output, which
# GitHub would not recognise as commands, so the markers are matched anywhere in a line and the
# group commands are written at the start of a line.
#
# Lines that look like errors (`error CS1234`, Game CI's `[ERROR]`) are also repeated as `::error::`
# annotations, up to ten, so they show on the run page without opening a group.
#
# At the end the recorded stages are appended to $GITHUB_STEP_SUMMARY as a bullet list, in the order
# they finished. Run the pipeline with `set -o pipefail` so a failed build still fails the step.
{
  writeShellApplication,
  gawk,
}:
writeShellApplication {
  name = "gameci-stages";

  runtimeInputs = [ gawk ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: ... | gameci-stages [--first TITLE] [--max-errors N]

      --first TITLE     title of the group that holds everything before the first stage marker
                        (default: "Unity start-up and project import")
      --max-errors N    how many error lines to repeat as annotations (default: 10)
    EOF
    }

    first="Unity start-up and project import"
    max_errors=10
    while [ $# -gt 0 ]; do
      case "$1" in
        --first) first="''${2:?--first needs a value}"; shift 2 ;;
        --max-errors) max_errors="''${2:?--max-errors needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "gameci-stages: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    exec awk -v first="$first" -v summary="''${GITHUB_STEP_SUMMARY:-}" -v maxerrors="$max_errors" '
      function out(s) { print s; fflush() }
      BEGIN { out("::group::" first); open = 1; errors = 0; count = 0 }
      {
        line = $0
        sub(/\r$/, "", line)
      }
      line ~ /\[CI\] stage start / {
        name = line
        sub(/.*\[CI\] stage start /, "", name)
        sub(/[ \t]+$/, "", name)
        if (open) out("::endgroup::")
        out("::group::" name)
        open = 1
        out(line)
        next
      }
      line ~ /\[CI\] stage end / {
        rest = line
        sub(/.*\[CI\] stage end /, "", rest)
        sub(/[ \t]+$/, "", rest)
        out(line)
        if (open) { out("::endgroup::"); open = 0 }
        n = split(rest, parts, " ")
        if (n >= 2) { count++; names[count] = parts[1]; times[count] = parts[2] }
        next
      }
      {
        out(line)
        if (errors < maxerrors && (line ~ /error CS[0-9]+/ || line ~ /\[ERROR\]/)) {
          message = line
          sub(/^[ \t]+/, "", message)
          gsub(/%/, "%25", message)
          out("::error::" message)
          errors++
        }
      }
      END {
        if (open) out("::endgroup::")
        if (summary != "") {
          for (i = 1; i <= count; i++) printf "- %s: %s\n", names[i], times[i] >> summary
          close(summary)
        }
      }
    '
  '';

  meta = {
    description = "Turn a Unity build log's stage markers into GitHub Actions log groups and timing lines";
    mainProgram = "gameci-stages";
    platforms = [ "x86_64-linux" ];
  };
}
