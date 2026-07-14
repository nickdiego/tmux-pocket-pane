#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nick Diego Yamane
#
# pocket-pane.sh: per-window toggleable named panes for tmux.
#
# Subcommands:
#   toggle <name>                       toggle the named pane (open / hide / reopen)
#   run    <exit-behavior> <name> <cmd> run cmd; handle pane exit per exit-behavior
#
# toggle is what users bind keys to:
#   bind -n M-a run-shell "#{@pocket-pane-path}/pocket-pane.sh toggle claude"
#
# Configuration (global tmux options, read by toggle):
#   @pocket-pane-<name>-cmd           command to run on first launch (required)
#   @pocket-pane-<name>-layout        comma-separated layout fields, all optional:
#                                     size:      40% (relative) or 40 (columns/lines), default 40%
#                                     direction: horizontal | vertical, default horizontal
#                                     span:      full | pane, default pane
#                                                  full: spans full window height/width (-f)
#                                                  pane: splits from the border pane (right/bottom)
#                                     example:   '40%,horizontal,full'
#   @pocket-pane-<name>-exit-behavior what to do when the command exits (default: close):
#                                     close:   kill the pane immediately (no notice)
#                                     prompt:  print exit status, wait for keypress, then kill
#                                     release: hand off to the user's shell
#                                     ask:     prompt: [c]lose / [r]elease
#
# State is tracked per-window via @pocket_pane_<name> storing "<pane_id>|<win_name>".
# The win_name anchors hidden panes for tmux-resurrect re-registration.

set -e

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pocket-pane.sh"

die() {
  local msg="pocket-pane: $*"
  printf '%s\n' "$msg" >&2
  tmux display-message -d 3000 "$msg" 2>/dev/null || true
  exit 1
}

# Release pocket tracking and hand the pane off to the user's shell,
# making it a regular pane.
hand_off_pane() {
  local name="$1"
  local pane_opt="@pocket_pane_${name}"
  tmux set-option -wqu "$pane_opt" 2>/dev/null || true
  exec "${SHELL:-bash}"
}

# In pane span mode, split from/join to the border pane so the pocket always
# appears at the window edge regardless of which pane is currently focused.
# Horizontal: top-most of the right-most panes (largest pane_left+pane_width, then smallest pane_top)
# Vertical:   left-most of the bottom-most panes (largest pane_top+pane_height, then smallest pane_left)
find_border_pane() {
  local win="$1" dir="$2"
  if [ "$dir" = "horizontal" ]; then
    tmux list-panes -t "$win" -F '#{pane_id} #{pane_left} #{pane_width} #{pane_top}' |
      awk '{print $2+$3, $4, $1}' | sort -k1,1rn -k2,2n | awk 'NR==1{print $3}'
  else
    tmux list-panes -t "$win" -F '#{pane_id} #{pane_top} #{pane_height} #{pane_left}' |
      awk '{print $2+$3, $4, $1}' | sort -k1,1rn -k2,2n | awk 'NR==1{print $3}'
  fi
}

cmd_toggle() {
  [ $# -eq 0 ] && die "toggle: <name> required"
  NAME="$1"
  PANE_OPT="@pocket_pane_${NAME}"
  PREFIX="@pocket-pane-${NAME}"

  CMD=$(tmux show-options -gqv "${PREFIX}-cmd" 2>/dev/null || true)
  [ -z "$CMD" ] && die "${PREFIX}-cmd not set"
  LAYOUT=$(tmux show-options -gqv "${PREFIX}-layout" 2>/dev/null || true)

  # Parse layout fields by type -- unambiguous, any order
  SIZE=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^[0-9]+%?$' | head -1)
  DIR=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^(horizontal|vertical)$' | head -1)
  SPAN=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^(full|pane)$' | head -1)
  SIZE="${SIZE:-40%}"
  DIR="${DIR:-horizontal}"
  SPAN="${SPAN:-pane}"
  EXIT_BEHAVIOR=$(tmux show-options -gqv "${PREFIX}-exit-behavior" 2>/dev/null || true)
  EXIT_BEHAVIOR="${EXIT_BEHAVIOR:-close}"
  case "$EXIT_BEHAVIOR" in
  close | prompt | release | ask) ;;
  *) die "invalid ${PREFIX}-exit-behavior '${EXIT_BEHAVIOR}': must be close, prompt, release, or ask" ;;
  esac

  [ "$DIR" = "horizontal" ] && DIR_FLAG="-h" || DIR_FLAG="-v"
  FULL_FLAG=
  [ "$SPAN" = "full" ] && FULL_FLAG="-f"

  CURR_WIN=$(tmux display-message -p '#{window_id}')
  CURR_PATH=$(tmux display-message -p '#{pane_current_path}')

  STORED=$(tmux show-options -wqv "$PANE_OPT" 2>/dev/null || true)
  PANE_ID=$(echo "$STORED" | cut -d'|' -f1)

  if [ -n "$PANE_ID" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$PANE_ID"; then
    PANE_WIN=$(tmux display-message -p -t "$PANE_ID" '#{window_id}' 2>/dev/null || true)

    if [ "$PANE_WIN" = "$CURR_WIN" ]; then
      # Visible → hide, but only if it's not the sole remaining pane
      if [ "$(tmux display-message -p '#{window_panes}')" -gt 1 ]; then
        WIN_NAME=$(echo "$STORED" | cut -d'|' -f2-)
        # -n sets the name atomically at creation; the global window-status-format
        # conditional in tmux-pocket-pane.tmux hides it before any status bar redraw.
        tmux break-pane -d -n "__pocket|${NAME}|${WIN_NAME}__" -s "$PANE_ID"
      fi
    else
      # Hidden → rejoin with configured geometry
      if [ -n "$FULL_FLAG" ]; then
        TARGET="$CURR_WIN"
      else
        TARGET=$(find_border_pane "$CURR_WIN" "$DIR")
      fi
      # shellcheck disable=SC2086
      tmux join-pane "$DIR_FLAG" $FULL_FLAG -l "$SIZE" -s "$PANE_ID" -t "$TARGET"
      tmux select-pane -t "$PANE_ID"
    fi
  else
    # No tracked pane or stale ID -- create a fresh one
    tmux set-option -wqu "$PANE_OPT" 2>/dev/null || true
    CURR_WIN_NAME=$(tmux display-message -p '#{window_name}')
    if [ -n "$FULL_FLAG" ]; then
      TARGET="$CURR_WIN"
    else
      TARGET=$(find_border_pane "$CURR_WIN" "$DIR")
    fi
    # shellcheck disable=SC2086
    tmux split-window "$DIR_FLAG" $FULL_FLAG -l "$SIZE" -c "$CURR_PATH" -t "$TARGET" \
      -- "$SELF" run "$EXIT_BEHAVIOR" "$NAME" "$CMD"
    PANE_ID=$(tmux display-message -p '#{pane_id}')
    tmux set-option -wq "$PANE_OPT" "${PANE_ID}|${CURR_WIN_NAME}"
  fi
}

cmd_run() {
  [ $# -lt 3 ] && die "run: <exit-behavior>, <name> and <cmd> required"
  EXIT_BEHAVIOR="$1"
  NAME="$2"
  CMD="$3"
  EXIT=0
  eval "$CMD" || EXIT=$?
  case "$EXIT_BEHAVIOR" in
  prompt)
    echo
    printf 'pocket-pane: process exited (status %d) -- press any key to close\n' "$EXIT"
    read -rsn1
    tmux kill-pane -t "$TMUX_PANE"
    ;;
  release)
    hand_off_pane "$NAME"
    ;;
  ask)
    echo
    printf 'pocket-pane: process exited (status %d) -- [C]lose / [r]elease: ' "$EXIT"
    read -rsn1 KEY
    echo
    case "$KEY" in
    r | R) hand_off_pane "$NAME" ;;
    *) tmux kill-pane -t "$TMUX_PANE" ;;
    esac
    ;;
  *) # close (default)
    tmux kill-pane -t "$TMUX_PANE"
    ;;
  esac
}

[ $# -eq 0 ] && die "usage: pocket-pane.sh <toggle|run> ..."
SUBCMD="$1"
shift
case "$SUBCMD" in
toggle) cmd_toggle "$@" ;;
run) cmd_run "$@" ;;
*) die "unknown subcommand '${SUBCMD}'" ;;
esac
