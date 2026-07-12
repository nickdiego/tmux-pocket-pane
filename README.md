# tmux-pocket-pane

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

Bind `pocket-pane.sh` to a key with a name and the command to run:

```tmux
# A full-height claude side pane at 40% width, toggled with M-a
bind -n M-a run-shell "#{@pocket-pane-path}/pocket-pane.sh claude 'claude' 40 h 1"
```

```
pocket-pane.sh <name> <cmd> [size=40] [dir=h] [full=0]
```

- **name** — unique identifier for this pane within the window
- **cmd** — command to run on first launch
- **size** — percentage of width (`h`) or height (`v`), default `40`
- **dir** — `h` side pane · `v` bottom pane, default `h`
- **full** — `1` spans the full window height/width · `0` splits from current pane

Press the key once to open, again to hide, again to get it back. Kill the pane
and the next keypress starts a fresh one.

## License

MIT
