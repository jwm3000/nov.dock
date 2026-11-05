# nov.dock: Floating Dock for Omarchy

An Omarchy shell plugin (cloned from `omarchy.dock`) for floating workspaces:

- **Dock**: pinned and running apps, with window dots. Super+click on an icon opens a new window of that app.
- **Downloads stack**: fans out macOS-style, with the newest download right above the stack. Images get thumbnails, text files open in the editor (nvim), and everything else opens in its default app.
- **Edge snapping** (native Hyprland plugin): drag a window to the left or right edge and it fills that half, stopping above the dock. Drag it to the top edge to maximize it.
- **Keyboard snapping** (only while a floating window has focus):

  | Keys | Action |
  |---|---|
  | Alt + ← / → | left / right half |
  | Alt + ↑ | maximize |
  | Alt + ↓ | restore the previous position and size |

- **Bar widget**: a small window icon whose switch turns window borders on or off for all floating windows. The change applies from a window's first frame.

## Install on another machine

The repo is private, so let git use your GitHub login first (once per machine):

```bash
gh auth login        # if not logged in yet
gh auth setup-git
```

Then:

```bash
omarchy plugin add https://github.com/jwm3000/nov.dock.git --yes
~/.config/omarchy/plugins/nov.dock/install.sh
```

`install.sh` does the following:

- builds the native snap plugin for the local Hyprland version
- links `hypr/nov-floating-dock.lua` to `~/.config/hypr/nov-floating-dock.lua`
- adds `require("hypr.nov-floating-dock")` to `~/.config/hypr/hyprland.lua` if it is missing
- reloads Hyprland, enables the plugin (which replaces the stock Omarchy dock) and restarts the shell

It needs `base-devel`, `pkgconf` and the Hyprland headers (shipped with the `hyprland` package).

## Update

```bash
omarchy plugin update nov.dock
~/.config/omarchy/plugins/nov.dock/install.sh
```

Run `install.sh` again after every Hyprland update too: the native plugin only loads into the Hyprland version it was built for.

## Layout

| Path | What |
|---|---|
| `manifest.json`, `*.qml`, `DockModel.js`, `i18n/` | the shell plugin |
| `desktop.py` | helper: window state, borders, downloads, new windows |
| `native/` | Hyprland snap plugin (C++), `make` / `make test` |
| `hypr/nov-floating-dock.lua` | loads the native plugin, Alt+arrow keys, border rule |
| `tests/` | `python3 -m unittest tests/test_desktop.py`; live smoke and visual tests |

The settings live outside the repo: the global borderless switch is stored in `~/.local/state/nov-dock/borderless`.
