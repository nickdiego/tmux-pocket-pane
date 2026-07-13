#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nick Diego Yamane
#
# tmux-pocket-pane — TPM entry point.
# Sets @pocket-pane-path so tmux.conf bindings can reference the scripts
# directory without hardcoding the install path.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmux set-option -gq "@pocket-pane-path" "$PLUGIN_DIR/scripts"
tmux set-option -gq "@resurrect-hook-post-restore-all" "$PLUGIN_DIR/scripts/restore-hook.sh"

# Wrap window-status-format so __pocket__ windows are invisible in the status
# bar the instant they are created (break-pane -n sets the name atomically).
# The case guard prevents double-wrapping on TPM reload.
_FMT=$(tmux show-options -gv window-status-format 2>/dev/null || true)
: "${_FMT:= #I:#W#F }"
case "$_FMT" in
*'__pocket|*__'*) ;;
*) tmux set-option -g window-status-format "#{?#{m:__pocket|*__,#{window_name}},,${_FMT}}" ;;
esac
