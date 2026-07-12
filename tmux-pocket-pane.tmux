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
