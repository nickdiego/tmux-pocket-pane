# tmux-pocket-pane

[![CI](https://github.com/nickdiego/tmux-pocket-pane/actions/workflows/ci.yml/badge.svg)](https://github.com/nickdiego/tmux-pocket-pane/actions/workflows/ci.yml)

> **Early development.** The configuration API (option names, layout syntax) is
> unstable and may change between releases without notice.

Pocket a tmux pane and pull it back out when you need it — same shell,
same session, right where you left it.

Each window gets its own pocket, independent from the others.

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'nickdiego/tmux-pocket-pane'
```

Then `prefix + I` to install.

## Usage

Declare each pocket pane with two global options, then bind the toggle key:

```tmux
set -g @pocket-pane-claude-cmd    'claude'
set -g @pocket-pane-claude-layout '40%,horizontal,full'
bind -n M-a run-shell "#{@pocket-pane-path}/pocket-pane.sh claude"
```

**`@pocket-pane-<name>-cmd`** — command to run on first launch (required)

**`@pocket-pane-<name>-layout`** — comma-separated layout fields, all optional,
any order (type determines meaning):

| Field | Values | Default |
|---|---|---|
| size | `40%` relative · `40` columns/lines | `40%` |
| direction | `horizontal` · `vertical` | `horizontal` |
| span | `full` (spans full window height/width) · `pane` (splits from border pane — right/bottom) | `pane` |

Examples: `'40%,horizontal,full'` · `'60%'` · `'30%,full'`

Press the key once to open, again to hide, again to get it back. Kill the pane
and the next keypress starts a fresh one.

## Resurrect

tmux-pocket-pane integrates with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
automatically, but resurrect itself needs to know how to restart the pocket pane's process.
Without this, the process won't be running after a restore and reclaim will find nothing to match.

Add the command to resurrect's process list using the `~name->cmd` pattern (fuzzy match → restart command):

```tmux
set -g @resurrect-processes '~claude->claude'
```

Multiple processes can be space-separated:

```tmux
set -g @resurrect-processes '~claude->claude ~node->node'
```

See [this dotfiles config](https://github.com/nickdiego/dotfiles/blob/main/tmux.conf#L135-L138) for a fully functional reference.

After a session restore:

- **Visible panes** are reclaimed by matching the running command against
  the configured `cmd`, filtered by whether the pane spans the full window
  dimension (the `full`/`pane` layout field). Works with
  [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) auto-saves.
- **Hidden panes** (detached windows) are re-registered via their encoded
  window name and linked back to the source window by name.

To opt out of visible-pane auto-reclaim:

```tmux
set -g @pocket-pane-claim-after-restore 'off'
```

## License

MIT
