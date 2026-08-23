#!/usr/bin/env bash
# Nudges Claude to post a progress update during a long tool chain.
#
# WHY THIS EXISTS: the working agreement in CLAUDE.md says long-running work gets
# a progress tick and never silence. Left to memory it got dropped repeatedly
# during forty-tool stretches. A hook does not forget.
#
# IT FIRES ON TIME AS WELL AS ON COUNT, AND TIME IS THE ONE THAT MATTERS. The
# first version counted tool calls only, and went silent for six minutes across
# four of them - because each was a ten-minute Pester run. Whichever threshold is
# crossed first now fires: twelve calls, or five minutes since the user last
# heard anything.
#
# HOW: PostToolUse keeps "<count> <epoch of last report>" per session and prints
# additionalContext when either threshold is crossed; the harness feeds that back
# to Claude. Silent otherwise, so the transcript stays clean. UserPromptSubmit
# restarts both, because a new instruction means the user has just been spoken to.
#
# The state is keyed by session id, so two Claude sessions in this repository
# count separately.
set -u

EVERY=12
SECONDS_BETWEEN=300
STATE_DIR="${TMPDIR:-/tmp}"

payload=$(cat)

session=$(printf '%s' "$payload" |
    grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' |
    head -1 |
    sed 's/.*"\([^"]*\)"$/\1/')

[ -n "$session" ] || session=default

state="$STATE_DIR/claude-heartbeat-$session"
now=$(date +%s)

case "${1:-count}" in
    reset)
        printf '0 %s' "$now" > "$state"
        ;;
    count)
        count=0
        since=$now

        if [ -f "$state" ]; then
            read -r count since < "$state" 2>/dev/null || true
        fi

        case "$count" in '' | *[!0-9]*) count=0 ;; esac
        case "$since" in '' | *[!0-9]*) since=$now ;; esac

        count=$(( count + 1 ))
        elapsed=$(( now - since ))

        if [ $(( count % EVERY )) -eq 0 ] || [ "$elapsed" -ge "$SECONDS_BETWEEN" ]; then
            printf '0 %s' "$now" > "$state"

            printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"HEARTBEAT DUE - %s tool calls and %s seconds since the user last heard from you. Post a short progress update now: what you just did, what you found, and what is next. Then carry on."}}' "$count" "$elapsed"
        else
            printf '%s %s' "$count" "$since" > "$state"
        fi
        ;;
esac

exit 0
