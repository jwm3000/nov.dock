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

-- Scrolling the window under the pointer, as on macOS: on a floating
-- workspace the pointer's focus follows the mouse, so hovering a window
-- behind the focused one and scrolling scrolls it, while the keyboard stays
-- with the focused window until a click moves it (follow_mouse = 2). Omarchy
-- sets focus-on-click (0) for floating workspaces and the user's own value
-- elsewhere, but it decides on monitor focus before the active workspace has
-- caught up, so the value it leaves can be the wrong one. This decides from
-- the workspace's saved layout instead, the same files Omarchy writes.
if file then
  local state_home = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
  local layouts = state_home .. "/omarchy/workspace-layouts/"
  local ok_user, user_follow_mouse = pcall(hl.get_config, "input.follow_mouse")
  if not ok_user or user_follow_mouse == 0 or user_follow_mouse == 2 then
    user_follow_mouse = 1
  end

  local function layout_of(id)
    for _, name in ipairs({ tostring(id) .. ".lua", "default.lua" }) do
      local handle = io.open(layouts .. name, "r")
      if handle then
        local text = handle:read("*a") or ""
        handle:close()
        local mode = text:match('mode%s*=%s*"([%a]+)"') or text:match('default%s*=%s*"([%a]+)"')
        if mode then return mode end
      end
    end
    return "dwindle"
  end

  local function scroll_under_pointer()
    local workspace = hl.get_active_workspace()
    if not workspace or not workspace.id or workspace.id < 1 then return end
    local floating = layout_of(workspace.id) == "floating"
    local want = floating and 2 or user_follow_mouse
    local ok, value = pcall(hl.get_config, "input.follow_mouse")
    if ok and value ~= want then
      hl.config({ input = { follow_mouse = want } })
    end
  end

  for _, event in ipairs({ "workspace.active", "monitor.focused", "config.reloaded", "hyprland.start" }) do
    hl.on(event, function()
      -- After Omarchy's own handler for the same event has set its value.
      hl.timer(function() pcall(scroll_under_pointer) end, { timeout = 30, type = "oneshot" })
    end)
  end

  -- Switching a workspace's layout has no event of its own, and the active
  -- workspace can settle after the events above.
  local function watch_follow_mouse()
    pcall(scroll_under_pointer)
    hl.timer(watch_follow_mouse, { timeout = 500, type = "oneshot" })
  end
  hl.timer(watch_follow_mouse, { timeout = 500, type = "oneshot" })
end

-- A short glow around the window Alt+Tab lands on, on floating workspaces,
-- so it is easy to see where focus went among overlapping windows. These
-- binds sit next to Omarchy's own Alt+Tab binds (which do the switching)
-- and pass the keys on; once the switch has happened, the dock draws the
-- glow around the new active window, titlebar included.
if file then
  local glow_off_file = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")) .. "/nov-dock/no-focus-glow"

  local function glow_active()
    -- Switched off in the bar menu.
    local off = io.open(glow_off_file, "r")
    if off then off:close() return end
    local ok, w = pcall(hl.get_active_window)
    if not ok or not w or not w.floating or not w.at or not w.size then return end
    local floating, titlebar = false, true
    for _, tag in ipairs(w.tags or {}) do
      if tag == "omarchy-floating-workspace" then floating = true end
      if tag == "spotifast-winamp" then titlebar = false end
    end
    if not floating then return end
    local bar = 0
    if titlebar and hl.plugin and hl.plugin.hyprbars then
      local got, height = pcall(hl.get_config, "plugin.hyprbars.bar_height")
      bar = got and tonumber(height) or 0
    end
    local got, rounding = pcall(hl.get_config, "decoration.rounding")
    rounding = got and tonumber(rounding) or 0
    hl.exec_cmd(string.format("omarchy-shell -q omarchy.dock focusGlow %d %d %d %d %d",
      math.floor(w.at.x), math.floor(w.at.y - bar), math.floor(w.size.x), math.floor(w.size.y + bar), math.floor(rounding)))
  end

  for _, keys in ipairs({ "ALT + TAB", "ALT + SHIFT + TAB" }) do
    hl.bind(keys, function()
      -- After Omarchy's bind for the same keys has moved focus.
      hl.timer(function() pcall(glow_active) end, { timeout = 40, type = "oneshot" })
    end, { description = "Show where focus went", non_consuming = true })
  end
end

-- Exposé: a three-finger swipe up shows every floating window of the
-- workspace side by side (the dock draws it), a swipe down leaves. The
-- horizontal three-finger swipe stays Omarchy's workspace switch. Switched
-- off in the bar menu, the swipe does nothing.
if file then
  local expose_off_file = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")) .. "/nov-dock/no-expose"

  local function expose_enabled()
    local off = io.open(expose_off_file, "r")
    if off then off:close() return false end
    return true
  end

  -- The overview follows the fingers, as the workspace swipe does: it
  -- starts as they move up, can be held, pushed back or carried on, and
  -- settles one way or the other when they lift. The finger travel goes to
  -- the dock as events on Hyprland's own event stream, which the shell
  -- reads anyway, rather than as a process per frame. A full swipe is
  -- Hyprland's workspace swipe distance.
  local SWIPE = 300
  local travel, active = 0, false
  local function send(message)
    pcall(hl.dispatch, hl.dsp.event("nov-expose>" .. message))
  end

  hl.gesture({
    fingers = 3,
    direction = "vertical",
    action = {
      start = function()
        active = expose_enabled()
        travel = 0
        if active then send("begin") end
      end,
      update = function(e)
        if not active or not e or not e.delta then return end
        -- Hyprland's delta follows the fingers: upwards is negative y.
        travel = travel - (e.delta.y or 0)
        send(string.format("move %.4f", travel / SWIPE))
      end,
      -- Hyprland calls the end of a gesture "finish".
      finish = function(e)
        if not active then return end
        active = false
        send((e and e.cancelled) and "end cancel" or "end done")
      end,
    },
  })

end

-- Apps that draw their own titlebar (a tab strip or a header bar) get no
-- second one from hyprbars on floating workspaces. The tag tells the dock's
-- Exposé to draw none either.
if file then
  hl.window_rule({
    name = "nov-dock-own-titlebar",
    match = { class = "^(chromium|google-chrome|ai\\.storyteller\\.photocraft)$" },
    tag = "+nov-dock-no-titlebar",
    ["hyprbars:no_bar"] = true,
  })
end
