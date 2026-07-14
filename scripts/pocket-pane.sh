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
  tmux set-option -wqu "@pocket_pane_layout_${name}" 2>/dev/null || true
  tmux set-option -wqu "@pocket_pane_layout_without_${name}" 2>/dev/null || true
  exec "${SHELL:-bash}"
}

# In pane span mode, split from/join to the border pane so the pocket always
# appears at the window edge regardless of which pane is currently focused.
# Horizontal: top-most of the right-most panes (largest pane_left+pane_width, then smallest pane_top)
# Vertical:   left-most of the bottom-most panes (largest pane_top+pane_height, then smallest pane_left)
find_border_pane() {
  local win="$1" dir="$2" excl="${3:-}"
  if [ "$dir" = "horizontal" ]; then
    tmux list-panes -t "$win" -F '#{pane_id} #{pane_left} #{pane_width} #{pane_top}' |
      awk -v excl="$excl" '$1 != excl {print $2+$3, $4, $1}' |
      sort -k1,1rn -k2,2n | awk 'NR==1{print $3}'
  else
    tmux list-panes -t "$win" -F '#{pane_id} #{pane_top} #{pane_height} #{pane_left}' |
      awk -v excl="$excl" '$1 != excl {print $2+$3, $4, $1}' |
      sort -k1,1rn -k2,2n | awk 'NR==1{print $3}'
  fi
}

# Proportionally resize all siblings in curr_win to fill it after the pocket pane has been
# removed, then snapshot the result as @pocket_pane_layout_without_<name>.
# sib_entries: space-separated "pane_id:size" tokens, sorted by position (left/top).
# sib_total:   sum of all sibling sizes before removal (used as the denominator).
_pocket_restore_siblings() {
  local name="$1" dir="$2" curr_win="$3" sib_entries="$4" sib_total="$5"
  [ "$sib_total" -le 0 ] && return
  local win_dim n_sibs win_avail resize_flag last_pid=""
  [ "$dir" = "horizontal" ] && resize_flag="-x" || resize_flag="-y"
  if [ "$dir" = "horizontal" ]; then
    win_dim=$(tmux display-message -p -t "$curr_win" '#{window_width}')
  else
    win_dim=$(tmux display-message -p -t "$curr_win" '#{window_height}')
  fi
  n_sibs=$(echo "$sib_entries" | wc -w | tr -d ' ')
  win_avail=$((win_dim - n_sibs + 1))
  for entry in $sib_entries; do last_pid="${entry%%:*}"; done
  for entry in $sib_entries; do
    local sib_pid sib_sz
    sib_pid="${entry%%:*}"
    sib_sz="${entry##*:}"
    [ "$sib_pid" = "$last_pid" ] && continue
    tmux resize-pane -t "$sib_pid" "$resize_flag" \
      "$((sib_sz * win_avail / sib_total))" 2>/dev/null || true
  done
  tmux set-option -wq -t "$curr_win" "@pocket_pane_layout_without_${name}" \
    "$(tmux display-message -p -t "$curr_win" '#{window_layout}')"
}

cmd_toggle() {
  [ $# -eq 0 ] && die "toggle: <name> required"
  local name="$1"
  local pane_opt="@pocket_pane_${name}"
  local prefix="@pocket-pane-${name}"

  local cmd
  cmd=$(tmux show-options -gqv "${prefix}-cmd" 2>/dev/null || true)
  [ -z "$cmd" ] && die "${prefix}-cmd not set"
  local layout
  layout=$(tmux show-options -gqv "${prefix}-layout" 2>/dev/null || true)

  # Parse layout fields by type -- unambiguous, any order
  local size dir span
  size=$(printf '%s\n' "$layout" | tr ',' '\n' | grep -E '^[0-9]+%?$' | head -1)
  dir=$(printf '%s\n' "$layout" | tr ',' '\n' | grep -E '^(horizontal|vertical)$' | head -1)
  span=$(printf '%s\n' "$layout" | tr ',' '\n' | grep -E '^(full|pane)$' | head -1)
  size="${size:-40%}"
  dir="${dir:-horizontal}"
  span="${span:-pane}"
  local exit_behavior
  exit_behavior=$(tmux show-options -gqv "${prefix}-exit-behavior" 2>/dev/null || true)
  exit_behavior="${exit_behavior:-close}"
  case "$exit_behavior" in
  close | prompt | release | ask) ;;
  *) die "invalid ${prefix}-exit-behavior '${exit_behavior}': must be close, prompt, release, or ask" ;;
  esac

  local dir_flag full_flag
  [ "$dir" = "horizontal" ] && dir_flag="-h" || dir_flag="-v"
  full_flag=
  [ "$span" = "full" ] && full_flag="-f"

  local curr_win curr_path
  curr_win=$(tmux display-message -p '#{window_id}')
  curr_path=$(tmux display-message -p '#{pane_current_path}')

  local stored pane_id
  stored=$(tmux show-options -wqv "$pane_opt" 2>/dev/null || true)
  pane_id=$(echo "$stored" | cut -d'|' -f1)

  if [ -n "$pane_id" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane_id"; then
    local pane_win
    pane_win=$(tmux display-message -p -t "$pane_id" '#{window_id}' 2>/dev/null || true)

    if [ "$pane_win" = "$curr_win" ]; then
      # Visible → hide, but only if it's not the sole remaining pane
      if [ "$(tmux display-message -p '#{window_panes}')" -gt 1 ]; then
        local win_name
        win_name=$(echo "$stored" | cut -d'|' -f2-)

        # Record current sibling sizes (sorted by position, pocket pane excluded) so
        # the proportional "without" layout can be recomputed at hide time, capturing
        # any manual resizes the user made while the pocket pane was visible.
        local sib_entries="" sib_total=0
        while IFS=: read -r sib_pid sib_sz; do
          sib_entries="${sib_entries}${sib_pid}:${sib_sz} "
          sib_total=$((sib_total + sib_sz))
        done < <(
          if [ "$dir" = "horizontal" ]; then
            tmux list-panes -t "$curr_win" -F '#{pane_id} #{pane_left} #{pane_width}'
          else
            tmux list-panes -t "$curr_win" -F '#{pane_id} #{pane_top} #{pane_height}'
          fi |
            awk -v excl="$pane_id" '$1 != excl {print $2, $1 ":" $3}' |
            sort -k1,1n | awk '{print $2}'
        )

        tmux set-option -wq "@pocket_pane_layout_${name}" \
          "$(tmux display-message -p '#{window_layout}')"
        # -n sets the name atomically at creation; the global window-status-format
        # conditional in tmux-pocket-pane.tmux hides it before any status bar redraw.
        tmux break-pane -d -n "__pocket|${name}|${win_name}__" -s "$pane_id"

        # Restore siblings proportionally (preserving their pre-hide A:B ratio), then
        # snapshot the result as the fresh "without" layout for next re-show or create.
        _pocket_restore_siblings "$name" "$dir" "$curr_win" "$sib_entries" "$sib_total"
      fi
    else
      # Hidden → rejoin with configured geometry
      local target
      target=$(find_border_pane "$curr_win" "$dir")
      # shellcheck disable=SC2086
      tmux join-pane "$dir_flag" $full_flag -l "$size" -s "$pane_id" -t "$target"
      tmux select-pane -t "$pane_id"
      local stored_layout
      stored_layout=$(tmux show-options -wqv "@pocket_pane_layout_${name}" 2>/dev/null || true)
      if [ -n "$stored_layout" ]; then
        tmux select-layout -t "$curr_win" "$stored_layout" 2>/dev/null || true
        tmux set-option -wqu "@pocket_pane_layout_${name}" 2>/dev/null || true
      fi
    fi
  else
    # No tracked pane or stale ID -- create a fresh one
    tmux set-option -wqu "$pane_opt" 2>/dev/null || true
    tmux set-option -wqu "@pocket_pane_layout_${name}" 2>/dev/null || true
    local curr_win_name target
    curr_win_name=$(tmux display-message -p '#{window_name}')
    target=$(find_border_pane "$curr_win" "$dir")
    # If P previously exited without being hidden, siblings may be skewed;
    # restore the saved pre-P layout before splitting so creation is always clean.
    local without_layout
    without_layout=$(tmux show-options -wqv "@pocket_pane_layout_without_${name}" 2>/dev/null || true)
    if [ -n "$without_layout" ]; then
      tmux select-layout -t "$curr_win" "$without_layout" 2>/dev/null || true
      target=$(find_border_pane "$curr_win" "$dir")
    fi
    # Store the current (pre-P) layout so every hide can restore siblings cleanly.
    tmux set-option -wq "@pocket_pane_layout_without_${name}" \
      "$(tmux display-message -p '#{window_layout}')"
    # shellcheck disable=SC2086
    tmux split-window "$dir_flag" $full_flag -l "$size" -c "$curr_path" -t "$target" \
      -- "$SELF" run "$exit_behavior" "$name" "$cmd"
    pane_id=$(tmux display-message -p '#{pane_id}')
    tmux set-option -wq "$pane_opt" "${pane_id}|${curr_win_name}"
  fi
}

# Restore sibling layout and clean up tracking state, then kill the pocket pane.
# Used by the internal close paths in cmd_run (where the process is still running).
_do_close() {
  local name="$1"
  local curr_win
  curr_win=$(tmux display-message -p '#{window_id}')
  if [ "$(tmux display-message -p '#{window_panes}')" -gt 1 ]; then
    local layout dir sib_entries="" sib_total=0
    layout=$(tmux show-options -gqv "@pocket-pane-${name}-layout" 2>/dev/null || true)
    dir=$(printf '%s\n' "$layout" | tr ',' '\n' | grep -E '^(horizontal|vertical)$' | head -1)
    dir="${dir:-horizontal}"
    while IFS=: read -r sib_pid sib_sz; do
      sib_entries="${sib_entries}${sib_pid}:${sib_sz} "
      sib_total=$((sib_total + sib_sz))
    done < <(
      if [ "$dir" = "horizontal" ]; then
        tmux list-panes -t "$curr_win" -F '#{pane_id} #{pane_left} #{pane_width}'
      else
        tmux list-panes -t "$curr_win" -F '#{pane_id} #{pane_top} #{pane_height}'
      fi |
        awk -v excl="$TMUX_PANE" '$1 != excl {print $2, $1 ":" $3}' |
        sort -k1,1n | awk '{print $2}'
    )
    # Detach to a background window first so sibling resize sees the full window without P.
    tmux break-pane -d -n "__pocket|${name}|closing__" -s "$TMUX_PANE"
    _pocket_restore_siblings "$name" "$dir" "$curr_win" "$sib_entries" "$sib_total"
  fi
  # Clear tracking on the user's window (we may now be in the background window after break-pane).
  tmux set-option -wqu -t "$curr_win" "@pocket_pane_${name}" 2>/dev/null || true
  tmux set-option -wqu -t "$curr_win" "@pocket_pane_layout_${name}" 2>/dev/null || true
  tmux kill-pane -t "$TMUX_PANE"
}

cmd_run() {
  [ $# -lt 3 ] && die "run: <exit-behavior>, <name> and <cmd> required"
  local exit_behavior="$1"
  local name="$2"
  local cmd="$3"
  local exit_code=0
  eval "$cmd" || exit_code=$?
  case "$exit_behavior" in
  prompt)
    echo
    printf 'pocket-pane: process exited (status %d) -- press any key to close\n' "$exit_code"
    read -rsn1
    _do_close "$name"
    ;;
  release)
    hand_off_pane "$name"
    ;;
  ask)
    echo
    printf 'pocket-pane: process exited (status %d) -- [C]lose / [r]elease: ' "$exit_code"
    local key
    read -rsn1 key
    echo
    case "$key" in
    r | R) hand_off_pane "$name" ;;
    *) _do_close "$name" ;;
    esac
    ;;
  *) # close (default)
    _do_close "$name"
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
