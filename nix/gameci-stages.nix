# `gameci-stages`: a filter for a Unity run's log that makes its stages, and its licence handling,
# visible in GitHub Actions.
#
#   gameci-build ... 2>&1 | gameci-stages
#
# Stages. One Unity run does several things in a row (pull the editor image, import the project,
# build Addressables, build the player), and a step in GitHub's UI can only be one thing. This reads
# the log as it streams and turns the stage markers into collapsible log groups, and into timing
# lines for the run summary:
#
#   [CI] stage start <Name>             closes the open group and opens one called <Name>
#   [CI] stage end <Name> <duration>    closes the group and records "<Name>: <duration>"
#
# The part of the log before the first marker is the first group (the build wrapper's own lines).
# Everything else passes through unchanged and live. Game CI indents what it prints, which GitHub
# would not recognise as commands, so the markers are matched anywhere in a line and the group
# commands are written at the start of a line.
#
# The stages are printed by two things: the build wrappers (gameci-build, gameci-test), which print
# `Image` around the pull of the editor image when it is not on the host yet, and then the stage
# the editor run starts in (`Import` for a build); and the build method inside Unity, which prints
# the rest (Addressables, Player) and the end of the import.
#
# Workflow commands. Game CI's step scripts print `::warning::`, `::error::` and `##[error]` lines
# (an activation that assigned no seat, a seat that could not be returned), but indented, so GitHub
# ignores them. They are printed again at the start of the line so they show on the run page. Lines
# that look like compile errors (`error CS1234`, Game CI's `[ERROR]`) are repeated as `::error::`
# annotations too, up to ten.
#
# Licence. A Personal seat is single-use: one that is taken and never returned stays consumed until it
# is released, and every later run on the account fails with "no available seats". Game CI only
# warns about that, and the run still ends green, so this reads the licence from the log. A grade
# needs positive evidence, never just the absence of a known failure:
#
#   activated and returned   a seat assignment AND a return confirmation were both seen
#   not returned             a seat assignment but no return confirmation: the seat may still be
#                            held. A red annotation, a caution block in the run summary, and
#                            LICENCE_LEAKED=true in $GITHUB_ENV so a later step can fail the run
#                            after the build has been published
#   no seat                  Unity said it had no seat to give: an annotation
#
# The patterns are the ones Game CI's own scripts and licensing checks use (return_license.sh in
# the pinned CLI, see cli.nix), because a restated pattern that drifts from them grades real
# successes as failures. Only the licensing methods that hold a seat are graded (personal, serial,
# floating); a licence file is not a seat.
#
# At the end the recorded stages are appended to $GITHUB_STEP_SUMMARY as a bullet list, in the order
# they finished, then the licence result. Run the pipeline with `set -o pipefail` so a failed build
# still fails the step.
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
                        (default: "Setup")
      --max-errors N    how many error lines to repeat as annotations (default: 10)

    Reads GITHUB_STEP_SUMMARY and GITHUB_ENV when they are set.
    EOF
    }

    first="Setup"
    max_errors=10
    while [ $# -gt 0 ]; do
      case "$1" in
        --first) first="''${2:?--first needs a value}"; shift 2 ;;
        --max-errors) max_errors="''${2:?--max-errors needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "gameci-stages: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    exec awk -v first="$first" -v summary="''${GITHUB_STEP_SUMMARY:-}" -v envfile="''${GITHUB_ENV:-}" -v maxerrors="$max_errors" '
      function out(s) { print s; fflush() }
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      function note(s) { if (summary != "") { print s >> summary; close(summary) } }
      function setenv(s) { if (envfile != "") { print s >> envfile; close(envfile) } }

      BEGIN {
        out("::group::" first)
        open = 1; errors = 0; count = 0
        method = ""; granted = 0; returned = 0; return_started = 0; bindings = 0; noseat = 0
      }

      {
        line = $0
        sub(/\r$/, "", line)
        t = trim(line)

        # licence evidence, read from every line whatever else the line is
        if (match(line, /Licensing method: [A-Za-z]+/)) {
          method = substr(line, RSTART, RLENGTH); sub(/.*: /, "", method)
        }
        if (method == "personal" && line ~ /Status: \[200\] ASSIGN_SEAT|Seat ID:|Serial number assigned to:.*UnityPers/) granted = 1
        if (method == "serial" && line ~ /Serial number assigned to/) granted = 1
        if (method == "floating" && line ~ /Acquired floating license/) granted = 1
        if (line ~ /Successfully returned ULF license|Successfully returned floating license|Successfully returned the entitlement license|License has been returned/) returned = 1
        if (line ~ /Returning personal license seat|Returning floating license/) return_started = 1
        if (line ~ /Machine bindings don.t match/) bindings = 1
        if (line ~ /No seat available|No license activation found for this computer|No valid Unity Editor license found|License is not active/) noseat = 1
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

      # workflow commands Game CI printed indented: print them at the start of the line
      t ~ /^::(warning|error|notice)[ :]/ { out(t); next }
      t ~ /^##\[(error|warning)\]/ {
        kind = (t ~ /^##\[error\]/) ? "error" : "warning"
        msg = t
        sub(/^##\[[a-z]+\] ?/, "", msg)
        out("::" kind "::" msg)
        next
      }

      {
        out(line)
        if (errors < maxerrors && (line ~ /error CS[0-9]+/ || line ~ /\[ERROR\]/)) {
          message = t
          gsub(/%/, "%25", message)
          out("::error::" message)
          errors++
        }
      }

      END {
        if (open) out("::endgroup::")

        for (i = 1; i <= count; i++) note(sprintf("- %s: %s", names[i], times[i]))

        if (method == "personal" || method == "serial" || method == "floating") {
          if (granted && returned) {
            note(sprintf("- Licence (%s): activated and returned", method))
          } else if (granted) {
            detail = return_started ? "the return was started but never confirmed" : "the return never started (the run was cut short, or Game CI changed what it prints)"
            if (bindings) detail = detail "; Unity reported that the licence is bound to a different machine"
            msg = "The Unity licence seat was taken but not returned: " detail ". The seat may still be held, and later runs on this account can fail with no available seats. Release it at https://id.unity.com or run game-ci return-license."
            out("::error::" msg)
            note(sprintf("- Licence (%s): NOT RETURNED", method))
            note("")
            note("> [!CAUTION]")
            note("> **The Unity licence seat was not returned.** " detail ".")
            note("> The seat may still be held, and later runs on this account can fail with no available seats.")
            note("> Release it at https://id.unity.com or run `game-ci return-license`.")
            setenv("LICENCE_LEAKED=true")
          } else if (noseat) {
            out("::error::Unity had no licence seat to give this machine. Check https://id.unity.com for seats held elsewhere, for example by an earlier run that did not return its seat.")
            note(sprintf("- Licence (%s): no seat available", method))
          } else {
            out("::warning::Could not confirm that the Unity licence was activated: the log has no seat assignment.")
            note(sprintf("- Licence (%s): activation not confirmed", method))
          }
        }
      }
    '
  '';

  meta = {
    description = "Turn a Unity run's stage markers into GitHub Actions log groups and timings, and make unreturned licence seats loud";
    mainProgram = "gameci-stages";
    platforms = [ "x86_64-linux" ];
  };
}
