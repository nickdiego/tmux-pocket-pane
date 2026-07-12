#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nick Diego Yamane
#
# restore-hook.sh — re-register pocket panes after a tmux-resurrect restore.
#
# Registered via @resurrect-hook-post-restore-all by tmux-pocket-pane.tmux.
#
# Runs in two phases:
#  1. Claim visible panes: match by command + span heuristic (covers continuum saves)
#  2. Re-register hidden panes: find __pocket|<name>|<win_name>__ detached windows
#
# Note: window names with spaces or '|' are not supported.

CLAIM_OPT=$(tmux show-options -gqv "@pocket-pane-claim-after-restore" 2>/dev/null || true)
CLAIM="${CLAIM_OPT:-on}"

LIST_WINS_FMT='#{session_name}:#{window_id} #{window_name}'
LIST_PANES_FMT='#{pane_id} #{pane_current_command} #{pane_height} #{pane_width} #{window_height} #{window_width}'

# Phase 1: claim visible panes restored in-place by resurrect.
# Matches by running command; span layout heuristic reduces false positives.
if [ "$CLAIM" != "off" ]; then
  while IFS=' ' read -r key val; do
    TMP="${key#@pocket-pane-}"
    NAME="${TMP%-cmd}"
    CMD=$(echo "$val" | tr -d '"')
    LAYOUT=$(tmux show-options -gqv "@pocket-pane-${NAME}-layout" 2>/dev/null || true)

    DIR=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^(horizontal|vertical)$' | head -1)
    SPAN=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^(full|pane)$' | head -1)
    [ -z "$DIR" ] && DIR="horizontal"
    [ -z "$SPAN" ] && SPAN="pane"

    while IFS=' ' read -r win_ref win_name; do
      # Skip pocket detached windows
      case "$win_name" in
      "__pocket|"*) continue ;;
      esac

      while IFS=' ' read -r pane_id pane_cmd ph pw wh ww; do
        [ "$pane_cmd" != "$CMD" ] && continue

        # Span heuristic: full pane must span full window dimension
        if [ "$SPAN" = "full" ] && [ "$DIR" = "horizontal" ] && [ "$ph" != "$wh" ]; then continue; fi
        if [ "$SPAN" = "full" ] && [ "$DIR" = "vertical" ] && [ "$pw" != "$ww" ]; then continue; fi
        if [ "$SPAN" = "pane" ] && [ "$DIR" = "horizontal" ] && [ "$ph" = "$wh" ]; then continue; fi
        if [ "$SPAN" = "pane" ] && [ "$DIR" = "vertical" ] && [ "$pw" = "$ww" ]; then continue; fi

        tmux set-option -wt "$win_ref" "@pocket_pane_${NAME}" "${pane_id}|${win_name}"
        break
      done < <(tmux list-panes -t "$win_ref" -F "$LIST_PANES_FMT" 2>/dev/null || true)
    done < <(tmux list-windows -a -F "$LIST_WINS_FMT" 2>/dev/null || true)
  done < <(tmux show-options -g 2>/dev/null | grep '^@pocket-pane-.*-cmd ' || true)
fi

# Phase 2: re-register hidden panes from __pocket|<name>|<win_name>__ detached windows.
while IFS=' ' read -r pocket_ref encoded; do
  NAME=$(printf '%s\n' "$encoded" | cut -d'|' -f2)
  TMP="${encoded#__pocket|*|}"
  WIN_NAME="${TMP%__}"

  [ -z "$NAME" ] && continue
  [ -z "$WIN_NAME" ] && continue

  PANE_ID=$(tmux list-panes -t "$pocket_ref" -F '#{pane_id}' 2>/dev/null | head -1 || true)
  [ -z "$PANE_ID" ] && continue

  SRC_WIN=$(tmux list-windows -a -F "$LIST_WINS_FMT" 2>/dev/null | grep -v ' __pocket|' |
    awk -v n="$WIN_NAME" '$2 == n {print $1; exit}')

  [ -n "$SRC_WIN" ] &&
    tmux set-option -wt "$SRC_WIN" "@pocket_pane_${NAME}" "${PANE_ID}|${WIN_NAME}"
done < <(tmux list-windows -a -F "$LIST_WINS_FMT" 2>/dev/null | grep ' __pocket|' || true)
