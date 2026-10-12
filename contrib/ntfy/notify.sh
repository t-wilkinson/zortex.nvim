#!/usr/bin/env bash
# contrib/ntfy/notify.sh - desktop side of zortex's ntfy notifications
#
# `ntfy subscribe` runs this for every message (see client.yml next to it).
# ntfy passes the arguments in the order defined in the config, and always
# exports NTFY_TITLE, NTFY_MESSAGE, NTFY_TAGS and NTFY_PRIORITY.
#
# Pomodoro messages carry a tag naming the event, so each gets its own sound:
#   pomodoro-work-start   a work session began
#   pomodoro-break-start  a short or long break began
#   pomodoro-restart      a new cycle began (after the long break, or by hand)
#   pomodoro-work-end / pomodoro-break-end   a phase ended, the next waits for you
# Everything else plays message.oga (with a 5% chance of a Wilhelm scream).
#
# Sounds are looked up next to this script, then in the freedesktop theme.
# Override any of them with ZORTEX_SOUND_WORK, _BREAK, _RESTART, _READY, _DEFAULT.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
TITLE="${1:-${NTFY_TITLE:-}}"
MESSAGE="${2:-${NTFY_MESSAGE:-}}"
SOUND_FILE="${3:-}"
TAGS="${4:-${NTFY_TAGS:-}}"

notify-send "$TITLE" "$MESSAGE"

FREEDESKTOP=/usr/share/sounds/freedesktop/stereo

# First readable file among the arguments
pick() {
  for f in "$@"; do
    [ -n "$f" ] && [ -r "$f" ] && { echo "$f"; return; }
  done
}

has_tag() { [[ ",$TAGS," == *",$1,"* ]]; }

if has_tag pomodoro-work-start; then
  SOUND=$(pick "$ZORTEX_SOUND_WORK" "$SCRIPT_DIR/work.oga" "$FREEDESKTOP/bell.oga")
elif has_tag pomodoro-break-start; then
  SOUND=$(pick "$ZORTEX_SOUND_BREAK" "$SCRIPT_DIR/break.oga" "$FREEDESKTOP/complete.oga")
elif has_tag pomodoro-restart; then
  SOUND=$(pick "$ZORTEX_SOUND_RESTART" "$SCRIPT_DIR/restart.oga" "$FREEDESKTOP/service-login.oga")
elif has_tag pomodoro-work-end || has_tag pomodoro-break-end; then
  SOUND=$(pick "$ZORTEX_SOUND_READY" "$SCRIPT_DIR/ready.oga" "$SCRIPT_DIR/message.oga" "$FREEDESKTOP/message.oga")
elif has_tag pomodoro-stop; then
  SOUND="" # stopping by hand needs no sound
elif [ -n "$SOUND_FILE" ] && [ -r "$SOUND_FILE" ]; then
  SOUND="$SOUND_FILE"
else
  if ((RANDOM % 100 < 95)); then
    SOUND=$(pick "$ZORTEX_SOUND_DEFAULT" "$SCRIPT_DIR/message.oga" "$FREEDESKTOP/message.oga")
  else
    SOUND=$(pick "$SCRIPT_DIR/wilhelm.ogg" "$SCRIPT_DIR/message.oga" "$FREEDESKTOP/message.oga")
  fi
fi

[ -n "$SOUND" ] && paplay "$SOUND"
exit 0
