-- Floating Dock: native drag detection, animated placement and preview.
-- Loaded independently of the old Floating Window Mode plugin.
local plugin = (os.getenv("HOME") or "") .. "/.config/omarchy/plugins/nov.dock/native/nov-floating-snap.so"
local file = io.open(plugin, "r")
if file then
  file:close()
  hl.plugin.load(plugin)
end

-- Alt+Arrow snaps the focused window while it sits on a floating workspace:
-- left and right halves, up maximizes, down puts it back where it was. The
-- keys are only bound while such a window has focus, so everywhere else apps
-- keep Alt+Arrow (a browser's back and forward, say).
if file then
  local snap_keys = {
    { "ALT + LEFT", "Snap window to the left half", "left" },
    { "ALT + RIGHT", "Snap window to the right half", "right" },
    { "ALT + UP", "Maximize window", "maximize" },
    { "ALT + DOWN", "Restore window", "restore" },
  }
  local snap_bound = false

  local function floating_window_focused()
    local window = hl.get_active_window()
    if not window or not window.floating then
      return false
    end
    for _, tag in ipairs(window.tags or {}) do
      if tag == "omarchy-floating-workspace" then
        return true
      end
    end
    return false
  end

  local function sync_snap_keys()
    local want = floating_window_focused()
    if want == snap_bound then
      return
    end
    for _, key in ipairs(snap_keys) do
      if want then
        local action = key[3]
        hl.bind(key[1], function()
          local snap = hl.plugin and hl.plugin.nov_floating_snap
          if snap and snap[action] then
            snap[action]()
          end
        end, { description = key[2] })
      else
        hl.unbind(key[1])
      end
    end
    snap_bound = want
  end

  local function sync()
    local ok = pcall(sync_snap_keys)
    if not ok then
      snap_bound = false
    end
  end

  for _, event in ipairs({ "window.active", "window.open", "window.move_to_workspace", "workspace.active", "config.reloaded", "hyprland.start" }) do
    hl.on(event, sync)
  end
  -- A reload rebuilds the binds without any focus change, so sync right away.
  sync()
end

-- Borderless windows: the dock's global switch. A named rule takes the border
-- off from a window's first frame on a floating workspace, rather than the
-- dock removing it a moment after the window appears. The switch turns the
-- rule on and off at runtime; at load it follows the saved setting.
if file then
  local state_home = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
  local flag = io.open(state_home .. "/nov-dock/borderless", "r")
  if flag then
    flag:close()
  end
  hl.window_rule({
    name = "nov-dock-borderless",
    enabled = flag ~= nil,
    match = { tag = "omarchy-floating-workspace" },
    border_size = 0,
  })
end
