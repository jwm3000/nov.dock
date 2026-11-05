#!/usr/bin/env python3
"""Small, argv-only bridge to the installed Omarchy workspace implementation."""
import heapq
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

TAG = "nov-dock-borderless"
# Borderless is one setting for every window on floating workspaces, kept
# across restarts; the dock applies it to windows as they open or move in.
BORDERLESS_FILE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "nov-dock/borderless"
# The Alt+Tab focus glow is on unless this file exists; the Hyprland hook
# checks for it before asking the dock to draw the glow.
NO_FOCUS_GLOW_FILE = BORDERLESS_FILE.with_name("no-focus-glow")


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=5).stdout.strip()


def mode(workspace):
    if not str(workspace).isdigit() or int(workspace) < 1:
        return "dwindle"
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy/workspace-layouts"
    for path in (state / f"{workspace}.lua", state / "default.lua"):
        if path.exists():
            match = re.search(r'(?:mode|default)\s*=\s*"([a-z]+)"', path.read_text())
            if match:
                return match[1]
    return "dwindle"


def state(workspace=None):
    active = json.loads(run("hyprctl", "activewindow", "-j"))
    if workspace is None:
        workspace = json.loads(run("hyprctl", "activeworkspace", "-j")).get("id", -1)
    active_workspace = active.get("workspace", {}).get("id", -1)
    return {"floating": mode(workspace) == "floating", "address": active.get("address", ""),
            "title": active.get("title", ""), "borderless": borderless(), "focusGlow": not NO_FOCUS_GLOW_FILE.exists(),
            "canControl": bool(active.get("floating")) and mode(active_workspace) == "floating"}


def borderless():
    return BORDERLESS_FILE.exists()


def set_border(window, hidden):
    """Show or hide one window's border; a no-op when it is already so."""
    address = window.get("address", "")
    if not re.fullmatch(r"0x[0-9a-fA-F]+", address) or (TAG in window.get("tags", [])) == hidden:
        return
    target = f'window = "address:{address}"'
    run("hyprctl", "dispatch", f'hl.dsp.window.set_prop({{ prop = "border_size", value = "{"0" if hidden else "unset"}", {target} }})')
    run("hyprctl", "dispatch", f'hl.dsp.window.tag({{ tag = "{"+" if hidden else "-"}{TAG}", {target} }})')


def on_floating_workspace(window, modes):
    workspace = window.get("workspace", {}).get("id", -1)
    if workspace not in modes:
        modes[workspace] = mode(workspace)
    return bool(window.get("floating")) and modes[workspace] == "floating"


def apply_borders(address=None):
    """Bring every floating window (or just one) in line with the setting."""
    hidden = borderless()
    modes = {}
    for window in json.loads(run("hyprctl", "clients", "-j")):
        if address and window.get("address") != address:
            continue
        if hidden and on_floating_workspace(window, modes):
            set_border(window, True)
        elif TAG in window.get("tags", []) and (not hidden or not on_floating_workspace(window, modes)):
            set_border(window, False)


def toggle_borders():
    if borderless():
        BORDERLESS_FILE.unlink(missing_ok=True)
    else:
        BORDERLESS_FILE.parent.mkdir(parents=True, exist_ok=True)
        BORDERLESS_FILE.touch()
    # The rule in ~/.config/hypr/nov-floating-dock.lua covers windows from
    # their first frame; open windows are brought in line below.
    try:
        run("hyprctl", "eval", f'hl.window_rule({{ name = "nov-dock-borderless", enabled = {"true" if borderless() else "false"} }})')
    except subprocess.SubprocessError:
        pass
    apply_borders()


def control(action, address):
    if not re.fullmatch(r"0x[0-9a-fA-F]+", address):
        raise ValueError("Invalid window address")
    windows = json.loads(run("hyprctl", "clients", "-j"))
    window = next((w for w in windows if w.get("address") == address), None)
    if not window or not window.get("floating") or mode(window.get("workspace", {}).get("id", -1)) != "floating":
        raise ValueError("The window is no longer on a floating workspace")
    target = f'window = "address:{address}"'
    if action == "minimize":
        run("omarchy-hyprland-window-minimize", address)
    else:
        raise ValueError("Unknown action")


def downloads(directory=None, limit=8):
    path = Path(directory or run("xdg-user-dir", "DOWNLOAD")).expanduser().absolute()
    def entries():
        with os.scandir(path) as files:
            for entry in files:
                if entry.name.startswith(".") or entry.name.endswith((".part", ".crdownload", ".download")):
                    continue
                try:
                    yield (entry.stat().st_mtime_ns, entry.name, entry.is_dir())
                except OSError:
                    continue
    items = heapq.nlargest(limit, entries()) if path.is_dir() else []
    import mimetypes
    def icon(name, directory):
        if directory:
            return "folder"
        mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
        return {"image": "image-x-generic", "video": "video-x-generic", "audio": "audio-x-generic",
                "text": "text-x-generic"}.get(mime.split('/')[0],
                "application-pdf" if mime == "application/pdf" else "application-x-generic")
    # Plain text and source-like files open in the editor (nvim in a
    # terminal) rather than through their desktop entry.
    text_types = {"application/json", "application/xml", "application/x-sh", "application/x-shellscript",
                  "application/toml", "application/yaml", "application/x-yaml", "application/javascript",
                  "application/sql", "application/x-python"}
    text_suffixes = {".txt", ".md", ".log", ".csv", ".conf", ".ini", ".cfg", ".lua", ".toml", ".yaml", ".yml",
                     ".json", ".sh", ".py", ".js", ".ts", ".rs", ".go", ".c", ".h", ".cpp", ".hpp", ".qml",
                     ".nfo", ".srt", ".env", ".diff", ".patch"}
    def text(name, directory):
        if directory:
            return False
        mime = mimetypes.guess_type(name)[0] or ""
        return mime.startswith("text/") or mime in text_types or Path(name).suffix.lower() in text_suffixes
    return {"uri": path.as_uri(), "items": [
        {"name": name, "uri": (path / name).as_uri(), "path": str(path / name), "directory": directory,
         "icon": icon(name, directory), "text": text(name, directory)}
        for _, name, directory in items]}


def new_window(desktop_id):
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio
    if not desktop_id or '/' in desktop_id or '\x00' in desktop_id:
        raise ValueError("Invalid desktop id")
    info = Gio.DesktopAppInfo.new(desktop_id if desktop_id.endswith('.desktop') else desktop_id + '.desktop')
    if not info:
        raise ValueError("Application desktop entry not found")
    executable = Path(info.get_executable() or '').name
    args = [word.replace('%%', '%') for word in shlex.split(info.get_commandline() or '')
            if not re.fullmatch(r'%[fFuUdDnNickvm]', word)]
    # These applications otherwise commonly activate a running window/tab.
    browsers = ('chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable', 'brave', 'brave-browser', 'firefox', 'librewolf', 'helium')
    if executable in browsers:
        args.insert(1, '--new-window')
        subprocess.Popen(['uwsm-app', '--', *args], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif 'new-window' in info.list_actions():
        info.launch_action('new-window', None)
    elif info.get_boolean('Terminal'):
        subprocess.Popen(['omarchy-launch-tui', *args], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        # Bypass D-Bus activation for a new process (e.g. terminals and editors).
        # Single-window applications ultimately decide whether to accept it.
        subprocess.Popen(['uwsm-app', '--', *args], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    command, *args = sys.argv[1:]
    if command == "state":
        print(json.dumps(state(args[0] if args else None)))
    elif command == "downloads":
        print(json.dumps(downloads()))
    elif command == "focus-glow":
        if NO_FOCUS_GLOW_FILE.exists():
            NO_FOCUS_GLOW_FILE.unlink()
        else:
            NO_FOCUS_GLOW_FILE.parent.mkdir(parents=True, exist_ok=True)
            NO_FOCUS_GLOW_FILE.touch()
    elif command == "border":
        toggle_borders()
    elif command == "apply-borders":
        apply_borders(args[0] if args else None)
    elif command == "new-window":
        new_window(args[0])
    else:
        control(command, args[0])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, IndexError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
