#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nick Diego Yamane
#
# pocket-pane.sh — toggle a named split pane in the current tmux window.
#
# Usage: pocket-pane.sh <name>
#
#   name   unique identifier for this pane (must match a @pocket-pane-<name>-cmd option)
#
# Configuration (global tmux options):
#   @pocket-pane-<name>-cmd     command to run on first launch (required)
#   @pocket-pane-<name>-layout  comma-separated layout fields, all optional:
#                               size:      40% (relative) or 40 (columns/lines), default 40%
#                               direction: horizontal | vertical, default horizontal
#                               span:      full | pane, default pane
#                                            full: spans full window height/width (-f)
#                                            pane: splits from the border pane (right/bottom)
#                               example:   '40%,horizontal,full'
#
# State is tracked per-window via @pocket_pane_<name> storing "<pane_id>|<win_name>".
# The win_name anchors hidden panes for tmux-resurrect re-registration.

set -e

NAME="${1:?Usage: pocket-pane.sh <name>}"
OPT="@pocket_pane_${NAME}"
PREFIX="@pocket-pane-${NAME}"

CMD=$(tmux show-options -gqv "${PREFIX}-cmd" 2>/dev/null || true)
[ -z "$CMD" ] && {
  echo "pocket-pane: ${PREFIX}-cmd not set" >&2
  exit 1
}
LAYOUT=$(tmux show-options -gqv "${PREFIX}-layout" 2>/dev/null || true)

# Parse layout fields by type — unambiguous, any order
SIZE=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^[0-9]+%?$' | head -1)
DIR=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^(horizontal|vertical)$' | head -1)
SPAN=$(printf '%s\n' "$LAYOUT" | tr ',' '\n' | grep -E '^(full|pane)$' | head -1)
SIZE="${SIZE:-40%}"
DIR="${DIR:-horizontal}"
SPAN="${SPAN:-pane}"

[ "$DIR" = "horizontal" ] && DIR_FLAG="-h" || DIR_FLAG="-v"
FULL_FLAG=
[ "$SPAN" = "full" ] && FULL_FLAG="-f"

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

CURR_WIN=$(tmux display-message -p '#{window_id}')
CURR_PATH=$(tmux display-message -p '#{pane_current_path}')

STORED=$(tmux show-options -wqv "$OPT" 2>/dev/null || true)
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
  # No tracked pane or stale ID — create a fresh one
  tmux set-option -wqu "$OPT" 2>/dev/null || true
  CURR_WIN_NAME=$(tmux display-message -p '#{window_name}')
  if [ -n "$FULL_FLAG" ]; then
    TARGET="$CURR_WIN"
  else
    TARGET=$(find_border_pane "$CURR_WIN" "$DIR")
  fi
  # shellcheck disable=SC2086
  tmux split-window "$DIR_FLAG" $FULL_FLAG -l "$SIZE" -c "$CURR_PATH" -t "$TARGET"
  PANE_ID=$(tmux display-message -p '#{pane_id}')
  tmux set-option -wq "$OPT" "${PANE_ID}|${CURR_WIN_NAME}"
  [ -n "$CMD" ] && tmux send-keys "$CMD" Enter
fi
