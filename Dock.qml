import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Qt.labs.folderlistmodel
import qs.Commons
import "DockModel.js" as DockModel
import "file:///usr/share/omarchy/shell/services" as OmarchyServices

// An app dock that shows on floating workspaces. A floating workspace has no
// tiles to hand the apps out, so the dock gives back a place to find them:
// pinned apps, running apps, and a grid of every app.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("desktop.py").toString().replace(/^file:\/\//, ""))
  property var downloads: []
  property string downloadsUri: ""
  property bool downloadsFailed: false
  property alias downloadsLoading: downloadsProc.running
  // The list is kept current all along, not read on the click that opens
  // the stack: read at start and again whenever the Downloads folder
  // changes. The stack then opens at once, its thumbnails already decoded.
  FolderListModel {
    id: downloadsWatch
    folder: root.downloadsUri
    showDirs: true
    showHidden: false
    sortField: FolderListModel.Unsorted
    onCountChanged: downloadsChanged.restart()
  }
  // A finishing download renames its partial file; one read covers both steps.
  Timer { id: downloadsChanged; interval: 400; onTriggered: root.refreshDownloads() }

  function refreshDownloads() {
    if (downloadsProc.running) return
    downloadsFailed = false
    downloadsProc.running = true
  }
  Process {
    id: downloadsProc
    command: ["python3", root.helper, "downloads"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.downloads = data.items
          root.downloadsUri = data.uri
        } catch (error) { root.downloads = []; root.downloadsFailed = true }
      }
    }
    onExited: function(code) { if (code !== 0) root.downloadsFailed = true }
  }

  readonly property string borderlessFile: Quickshell.env("XDG_STATE_HOME")
    ? Quickshell.env("XDG_STATE_HOME") + "/nov-dock/borderless"
    : Quickshell.env("HOME") + "/.local/state/nov-dock/borderless"
  function applyBorders(address) {
    // A new window is mapped before its rules settle; give it a moment.
    Quickshell.execDetached(["sh", "-c", "sleep 0.15; [ -e \"$1\" ] && exec python3 \"$2\" apply-borders \"$3\"", "sh",
      root.borderlessFile, root.helper, address])
  }

  // Minimized windows get a slot of their own between the apps and the
  // Downloads stack, in the order they were minimized, macOS-style. They are
  // kept as a ListModel keyed by address, like the apps, so a slot (and its
  // snapshot) survives other windows coming and going.
  property var minimizedOrder: []
  property alias minimizedModel: minimizedModel
  ListModel { id: minimizedModel }

  function bareAddress(address) { return String(address || "").replace(/^0x/, "") }

  readonly property var minimizedWindows: {
    var order = root.minimizedOrder
    var out = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var workspace = toplevels[i].workspace
      var wayland = toplevels[i].wayland
      if (!workspace || !wayland || wayland.parent || !DockModel.isMinimizedWorkspace(workspace.name)) continue
      var entry = wayland.appId ? root.entryForAppId(wayland.appId) : null
      out.push({
        address: root.bareAddress(toplevels[i].address),
        key: entry ? entry.id : String(wayland.appId || ""),
        toplevel: wayland,
        minimized: true,
        workspaceId: -1
      })
    }
    out.sort(function(a, b) { return order.indexOf(a.address) - order.indexOf(b.address) })
    return out
  }

  readonly property var minimizedByAddress: {
    var byAddress = {}
    for (var i = 0; i < root.minimizedWindows.length; i++) byAddress[root.minimizedWindows[i].address] = root.minimizedWindows[i]
    return byAddress
  }

  function minimizedFor(address) { return root.minimizedByAddress[root.bareAddress(address)] || null }

  onMinimizedWindowsChanged: syncMinimizedModel()
  function syncMinimizedModel() {
    var keys = root.minimizedWindows.map(function(window) { return window.address })
    for (var i = 0; i < keys.length; i++) {
      if (i < minimizedModel.count && minimizedModel.get(i).address === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < minimizedModel.count; j++) {
        if (minimizedModel.get(j).address === keys[i]) { found = j; break }
      }
      if (found >= 0) minimizedModel.move(found, i, 1)
      else minimizedModel.insert(i, { address: keys[i] })
    }
    if (minimizedModel.count > keys.length) minimizedModel.remove(keys.length, minimizedModel.count - keys.length)
  }

  // Window geometry straight from Hyprland, for the genie: the toplevel list
  // Quickshell keeps does not follow a window being dragged around.
  property var geometryRequests: []
  function clientGeometry(address, callback) {
    root.geometryRequests.push({ address: root.bareAddress(address), callback: callback })
    if (!geometryProc.running) geometryProc.running = true
  }
  Process {
    id: geometryProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var clients = []
        try { clients = JSON.parse(text) } catch (error) {}
        var requests = root.geometryRequests
        root.geometryRequests = []
        for (var i = 0; i < requests.length; i++) {
          var found = null
          for (var j = 0; j < clients.length; j++) {
            if (root.bareAddress(clients[j].address) === requests[i].address) { found = clients[j]; break }
          }
          requests[i].callback(found && found.at && found.size
            ? Qt.rect(found.at[0], found.at[1], found.size[0], found.size[1]) : null)
        }
      }
    }
    onExited: if (root.geometryRequests.length > 0) Qt.callLater(function() { geometryProc.running = true })
  }

  // Exposé: the floating windows of the focused monitor's workspace, side by
  // side. Only on floating workspaces; window geometry comes straight from
  // Hyprland, as the toplevel list does not follow windows being moved.
  // hyprbars' titlebar follows the theme, so its look (height, color, text
  // color and size) is read along with the windows every time Exposé opens.
  function argb(value) {
    var v = Number(value) || 0
    var a = Math.floor(v / 16777216) % 256, r = Math.floor(v / 65536) % 256, g = Math.floor(v / 256) % 256, b = v % 256
    return Qt.rgba(r / 255, g / 255, b / 255, a / 255)
  }
  function parseTitlebar(lines) {
    var values = []
    for (var i = 0; i < 4; i++) {
      try { values.push(JSON.parse(lines[i])) } catch (error) { values.push(null) }
    }
    function intOf(v) { return v && v.int !== undefined ? v.int : null }
    return {
      height: intOf(values[0]) || 0,
      color: intOf(values[1]) !== null ? root.argb(intOf(values[1])) : "#353b44",
      text: intOf(values[2]) !== null ? root.argb(intOf(values[2])) : "#d2d7da",
      textSize: intOf(values[3]) || 12
    }
  }
  property bool exposeLoading: false
  function toggleExpose() {
    var dock = root.focusedDock()
    if (!dock) return
    if (dock.exposeOpen()) { dock.closeExpose(); return }
    var monitor = Hyprland.focusedMonitor
    var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    if (!root.isFloating(workspace) || exposeProc.running) return
    exposeProc.workspace = workspace
    exposeProc.dock = dock
    exposeProc.running = true
  }
  // The window picked in Exposé: focused and in front. A maximized window is
  // not raised above windows that were focused over it, so those go below
  // it instead, topmost first, which keeps their order among themselves.
  function exposeChoose(address, windows) {
    var bare = root.bareAddress(address)
    if (!/^[0-9a-fA-F]+$/.test(bare)) return
    var target = "window = \"address:0x" + bare + "\""
    var steps = ["hl.dsp.focus({ " + target + " })", "hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })"]
    var chosen = null
    for (var i = 0; i < windows.length; i++) if (root.bareAddress(windows[i].address) === bare) chosen = windows[i]
    if (chosen && chosen.maximized) {
      var others = windows.filter(function(w) { return root.bareAddress(w.address) !== bare })
      others.sort(function(a, b) { return a.stack - b.stack })
      for (var j = 0; j < others.length; j++)
        steps.push("hl.dsp.window.alter_zorder({ mode = \"bottom\", window = \"address:0x" + root.bareAddress(others[j].address) + "\" })")
    }
    Util.execDetached(steps.map(function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }).join(" && "))
  }

  function closeExpose() {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) windows[i].closeExpose()
  }
  Process {
    id: exposeProc
    property int workspace: -1
    property var dock: null
    command: ["sh", "-c", "hyprctl clients -j; echo '@@nov-dock@@'; for o in bar_height bar_color col.text bar_text_size; do hyprctl getoption plugin:hyprbars:$o -j 2>/dev/null | tr -d '\\n'; echo; done"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = text.split("@@nov-dock@@")
        var clients = []
        try { clients = JSON.parse(parts[0]) } catch (error) { return }
        var titlebar = root.parseTitlebar(String(parts[1] || "").trim().split("\n"))
        var dock = exposeProc.dock
        if (!dock) return
        var byAddress = {}
        var toplevels = Hyprland.toplevels.values
        for (var i = 0; i < toplevels.length; i++) byAddress[root.bareAddress(toplevels[i].address)] = toplevels[i]
        var screen = dock.screen
        var list = []
        for (var j = 0; j < clients.length; j++) {
          var c = clients[j]
          if (!c.mapped || c.hidden || !c.floating || !c.workspace || c.workspace.id !== exposeProc.workspace) continue
          if (!c.size || c.size[0] < 20 || c.size[1] < 20) continue
          var top = byAddress[root.bareAddress(c.address)]
          if (!top || !top.wayland) continue
          var entry = c.class ? root.entryForAppId(c.class) : null
          // Floating windows carry hyprbars' titlebar above their content,
          // except those with a rule against it: apps with a titlebar of their
          // own, and Spotifast in Winamp mode. Tags set by a rule end in "*".
          var tags = (c.tags || []).map(function(tag) { return String(tag).replace(/\*$/, "") })
          var bar = tags.indexOf("nov-dock-no-titlebar") >= 0 || tags.indexOf("spotifast-winamp") >= 0 ? 0 : titlebar.height
          list.push({
            address: c.address,
            title: String(c.title || c.class || ""),
            icon: root.iconFor({ key: entry ? entry.id : String(c.class || "") }),
            home: Qt.rect(c.at[0] - screen.x, c.at[1] - bar - screen.y, c.size[0], c.size[1] + bar),
            bar: bar,
            stack: Number(c.focusHistoryID) || 0,
            maximized: Number(c.fullscreen) === 1,
            toplevel: top.wayland
          })
        }
        dock.openExpose(list, titlebar)
      }
    }
  }

  // The dock on the screen a global point is on, or on the focused screen.
  function dockAt(globalX, globalY) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      var screen = windows[i].screen
      if (globalX >= screen.x && globalX < screen.x + screen.width && globalY >= screen.y && globalY < screen.y + screen.height)
        return windows[i]
    }
    return root.focusedDock()
  }
  function focusedDock() {
    var monitor = Hyprland.focusedMonitor
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) if (windows[i].monitor === monitor) return windows[i]
    return windows.length > 0 ? windows[0] : null
  }

  // A window just went to the minimized workspace, however it was sent there
  // (its titlebar, Super+M, the dock menu): pour it into its new slot.
  function onMinimized(address) {
    address = root.bareAddress(address)
    var order = root.minimizedOrder.filter(function(other) { return other !== address })
    order.push(address)
    root.minimizedOrder = order
    root.clientGeometry(address, function(rect) {
      var window = root.minimizedFor(address)
      if (!rect || !window) return
      var dock = root.dockAt(rect.x + rect.width / 2, rect.y + rect.height / 2)
      if (dock) dock.genieMinimize(window.toplevel, address, rect)
    })
  }

  function minimize(window) {
    var address = String(window.address || "")
    if (address.indexOf("0x") !== 0) address = "0x" + address
    if (/^0x[0-9a-fA-F]+$/.test(address))
      Quickshell.execDetached(["python3", root.helper, "minimize", address])
  }

  // Since Omarchy 4.5 user plugins only get shell.appLibrary when they are a
  // "menu" kind, so the dock keeps its own app library as a fallback.
  readonly property var appLibrary: shell && shell.appLibrary ? shell.appLibrary : localAppLibrary
  OmarchyServices.AppLibrary { id: localAppLibrary }
  // The dock's settings (pins, position, auto-hide) live under "dock" in the
  // user's shell.json, with Omarchy's shell.json as the defaults. A user
  // plugin's scoped shell API does not hand out the shell config, so the dock
  // reads both files itself and follows them as they change. Without this
  // the dock saw no pins at all, and keeping one app in the dock saved that
  // app alone, dropping every other pin.
  readonly property string userShellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  readonly property string defaultShellConfigPath: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/config/omarchy/shell.json"
  property var userDockConfig: null
  property var defaultsDockConfig: null

  function dockSection(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      return parsed && typeof parsed === "object" && parsed.dock && typeof parsed.dock === "object" ? parsed.dock : ({})
    } catch (error) {
      return null
    }
  }

  FileView {
    id: userShellConfigFile
    path: root.userShellConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var section = root.dockSection(text())
      // A half-written or broken file keeps the last good settings.
      if (section !== null) root.userDockConfig = section
    }
    onLoadFailed: function(error) { root.userDockConfig = ({}) }
  }

  FileView {
    id: defaultShellConfigFile
    path: root.defaultShellConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var section = root.dockSection(text())
      if (section !== null) root.defaultsDockConfig = section
    }
    onLoadFailed: function(error) { root.defaultsDockConfig = ({}) }
  }

  readonly property var dockConfig: root.userDockConfig
    || (shell && shell.shellConfig && shell.shellConfig.dock ? shell.shellConfig.dock : ({}))
  readonly property var defaultDockConfig: root.defaultsDockConfig
    || (shell && shell.defaultsConfig && shell.defaultsConfig.dock ? shell.defaultsConfig.dock : ({}))
  // Until shell.json has been read the pins are unknown: nothing may be saved
  // from them, or the save would overwrite the real ones.
  readonly property bool pinsKnown: root.userDockConfig !== null && root.defaultsDockConfig !== null
  readonly property string position: DockModel.normalizePosition(dockConfig.position)
  readonly property bool vertical: DockModel.isVertical(position)
  readonly property bool autohide: dockConfig.autohide === true

  // Room the snap plugin keeps free for the dock, so a window snapped to the
  // left or right half ends just short of it: the strip of icons plus a gap
  // on each side, as DockWindow lays it out. An auto-hiding dock needs none.
  readonly property int snapReserve: autohide ? 0
    : Style.spacing.xs * 2 + Math.round(36 * Style.fontScale) + Style.spacing.md * 2
  function reportSnapReserve() {
    var lua = "hl.config({ plugin = { nov_floating_snap = { dock_edge = \"" + root.position
      + "\", dock_reserve = " + Math.max(0, root.snapReserve) + " } } })"
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }
  onSnapReserveChanged: reportSnapReserve()
  onPositionChanged: reportSnapReserve()
  // A config reload resets plugin values, and the plugin may load after the
  // shell starts, so the report is sent again a moment later.
  Timer { id: reserveRetry; interval: 1500; onTriggered: root.reportSnapReserve() }

  // The dock's order for the session, as desktop ids, set when the user moves
  // an app: a drag moves it, and keeping it in the dock puts it at the end. An
  // app the order does not know yet goes at the end. Pins are saved in this
  // order.
  property var order: []

  // A reorder shows at once rather than when the saved config comes back.
  property var pendingPins: null
  onDockConfigChanged: pendingPins = null

  // Entries that can claim a terminal app's window: those run in a terminal,
  // and those that hand the terminal an app id of their own.
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  function entryForAppId(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry
    var id = DockModel.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  // A pinned app that is not installed has nothing to launch, so it is left
  // out until it is. Windows are matched to the desktop entry that claims them.
  readonly property var items: {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = (root.pendingPins || DockModel.pinnedIds(dockConfig, defaultDockConfig)).filter(function(id) {
      return !!DesktopEntries.byId(id)
    })

    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var entry = root.entryForAppId(toplevel.appId)
      var workspace = toplevels[i].workspace
      windows.push({
        key: entry ? entry.id : toplevel.appId,
        hasEntry: !!entry && !entry.noDisplay,
        workspaceId: workspace ? workspace.id : -1,
        minimized: !!workspace && DockModel.isMinimizedWorkspace(workspace.name),
        address: toplevels[i].address,
        toplevel: toplevel
      })
    }

    return DockModel.orderItems(DockModel.buildItems(pinned, windows), root.order)
  }

  readonly property var itemsByKey: {
    var byKey = {}
    for (var i = 0; i < root.items.length; i++) byKey[root.items[i].key] = root.items[i]
    return byKey
  }

  function itemFor(key) {
    return root.itemsByKey[key] || null
  }

  // The dock's slots follow this model rather than the items list itself, so
  // a slot survives a window opening or closing instead of being rebuilt
  // under the pointer, and a reorder moves slots rather than replacing them.
  property alias itemModel: itemModel

  ListModel { id: itemModel }

  onItemsChanged: syncItemModel()

  function shownKeys() {
    return root.items.map(function(item) { return item.key })
  }

  function syncItemModel() {
    var keys = root.items.map(function(item) { return item.key })
    for (var i = 0; i < keys.length; i++) {
      if (i < itemModel.count && itemModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < itemModel.count; j++) {
        if (itemModel.get(j).key === keys[i]) { found = j; break }
      }
      if (found >= 0) itemModel.move(found, i, 1)
      else itemModel.insert(i, { key: keys[i] })
    }
    if (itemModel.count > keys.length) itemModel.remove(keys.length, itemModel.count - keys.length)
    root.settleLaunches()
  }

  // An app launched from the dock pulses its dot until a new window of it
  // shows up, or for ten seconds if none does.
  property var launches: ({})
  readonly property int launchTimeout: 10000

  function isLaunching(key) {
    return root.launches[key] !== undefined
  }

  function settleLaunches() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launches) {
      var launch = root.launches[key]
      var item = root.itemsByKey[key]
      var windows = item ? item.windows.length : 0
      if (windows > launch.windows || now - launch.at > root.launchTimeout) changed = true
      else next[key] = launch
    }
    if (changed) root.launches = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launches).length > 0
    onTriggered: root.settleLaunches()
  }

  function entryFor(item) {
    return item ? DesktopEntries.byId(item.key) : null
  }

  // App icons at their best: Omarchy's index keeps whichever PNG it finds
  // first, which for apps that ship only PNGs (Steam among them) is often a
  // 16 or 48 px one beside a 256 px one. This index prefers a scalable SVG
  // and otherwise the largest PNG of each name, across the same icon dirs.
  property var sharpIcons: ({})
  property var pendingSharpIcons: ({})
  Process {
    id: sharpIconScan
    command: ["bash", "-c", [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      '{ for base in $dirs; do [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null; done;',
      '  find /usr/share/pixmaps -maxdepth 1 \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null; } |',
      'awk \'{ file = $0; sub(/.*\\//, "", file); name = file; sub(/\\.[^.]*$/, "", name);',
      '  if (file ~ /\\.svg$/) score = 100000;',
      '  else if (match($0, /\\/[0-9]+x[0-9]+(@[0-9]+x?)?\\//)) { size = substr($0, RSTART + 1, RLENGTH - 2); sub(/x.*/, "", size); score = size + 0; if ($0 ~ /@2x?\\//) score *= 2 }',
      '  else score = 1;',
      '  if (!(name in best) || score > best[name]) { best[name] = score; path[name] = $0 } }',
      '  END { for (n in path) print n "\\t" path[n] }\''
    ].join(" ")]
    stdout: SplitParser {
      onRead: function(line) {
        var tab = line.indexOf("\t")
        if (tab > 0) root.pendingSharpIcons[line.slice(0, tab)] = line.slice(tab + 1)
      }
    }
    onStarted: root.pendingSharpIcons = ({})
    onExited: root.sharpIcons = root.pendingSharpIcons
  }
  // New apps bring new icons.
  readonly property int appCount: DesktopEntries.applications.values.length
  onAppCountChanged: sharpIconRescan.restart()
  Timer { id: sharpIconRescan; interval: 1500; onTriggered: if (!sharpIconScan.running) sharpIconScan.running = true }

  // An icon name (or path) from a desktop entry, as an image source.
  function iconSource(icon) {
    var value = String(icon || "")
    var sharp = value && value.charAt(0) !== "/" && value.indexOf("://") < 0 ? root.sharpIcons[value] : ""
    if (sharp) return "file://" + sharp
    return root.appLibrary ? root.appLibrary.iconSource(value) : Quickshell.iconPath(value, true)
  }

  function iconFor(item) {
    var entry = entryFor(item)
    var icon = entry && entry.icon ? entry.icon : (item ? item.key : "")
    return root.iconSource(icon)
  }

  function launch(item) {
    var entry = entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length }
    root.launches = next
    root.launchEntry(entry)
  }

  function newWindow(item) {
    var entry = entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length }
    root.launches = next
    Quickshell.execDetached(["python3", root.helper, "new-window", entry.id])
  }

  function launchEntry(entry) {
    if (entry && root.appLibrary) root.appLibrary.launch(entry.id, entry.name)
  }

  function activate(item) {
    if (!item) return
    if (item.windows.length === 0) {
      root.launch(item)
      return
    }
    var monitor = Hyprland.focusedMonitor
    var workspaceId = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var index = DockModel.pickWindow(item.windows.map(function(window) {
      return { workspaceId: window.workspaceId, minimized: window.minimized, activated: window.toplevel.activated }
    }), workspaceId)
    root.bringForward(item.windows[index])
  }

  // A window the dock brings forward lands on top of the others, focused; a
  // minimized one first comes back to the workspace in front of the user.
  function bringForward(window) {
    var address = String(window.address || "")
    if (!address) {
      window.toplevel.activate()
      return
    }
    if (address.indexOf("0x") !== 0) address = "0x" + address
    var target = "window = \"address:" + address + "\""
    var steps = []
    var after = []
    if (window.minimized && !window.genieDone) {
      // Out of the slot first, then the real window takes the snapshot's place.
      var bare = root.bareAddress(address)
      var minimizedWindow = root.minimizedFor(bare)
      var dock = root.focusedDock()
      if (minimizedWindow && dock) {
        root.clientGeometry(bare, function(rect) {
          var again = Object.assign({}, window, { genieDone: true })
          if (!rect) { root.bringForward(again); return }
          dock.genieRestore(minimizedWindow.toplevel, bare, rect, function() { root.bringForward(again) })
        })
        return
      }
    }
    if (window.minimized) {
      var monitor = Hyprland.focusedMonitor
      var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (!(workspace >= 1)) return
      // A restored window is simply there again, without animating in.
      steps.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", " + target + " })")
      steps.push("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })")
      after.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
    var command = steps.map(dispatch).join(" && ")
    if (after.length > 0) command += "; sleep 0.4; " + after.map(dispatch).join("; ")
    Util.execDetached(command)
  }

  function quit(item) {
    if (!item) return
    var windows = item.windows.slice()
    for (var i = 0; i < windows.length; i++) windows[i].toplevel.close()
  }

  function openApps() {
    appGrid.open()
  }

  readonly property var pinnedKeys: root.pendingPins || DockModel.pinnedIds(root.dockConfig, root.defaultDockConfig)

  function isPinned(key) {
    return root.pinnedKeys.indexOf(key) >= 0
  }

  // Moves an app to a slot in the dock's order, pinning it there; the pins are
  // saved in the new order. The index counts the slots once the app has left
  // its own.
  function placeAt(key, index) {
    if (!key) return
    root.order = DockModel.orderWithKeyAt(root.shownKeys(), key, index)
    var pinned = {}
    root.pinnedKeys.forEach(function(other) { pinned[other] = true })
    pinned[key] = true
    root.savePins(DockModel.pinsInOrder(root.order, pinned, root.pinnedKeys))
  }

  // A reorder shows at once; the saved config catches up after.
  function savePins(pins) {
    if (!root.pinsKnown) return
    root.pendingPins = pins
    Util.execDetached("omarchy-dock pinned " + pins.map(function(id) { return Util.shellQuote(id) }).join(" "))
  }

  function moveItem(fromIndex, toIndex) {
    if (fromIndex !== toIndex) root.placeAt(root.shownKeys()[fromIndex], toIndex)
  }

  // An app dropped before the slot at index, counted as the slots stand.
  function pinAt(key, index) {
    var from = root.shownKeys().indexOf(key)
    root.placeAt(key, from >= 0 && from < index ? index - 1 : index)
  }

  // Keeping an app in the dock puts it at the end; taking one out leaves it in
  // its slot while it still runs.
  function setPinned(key, pinned) {
    if (!key || !root.pinsKnown) return
    if (pinned) {
      root.placeAt(key, root.shownKeys().length)
    } else {
      root.pendingPins = root.pinnedKeys.filter(function(other) { return other !== key })
      Util.execDetached("omarchy-dock unpin " + Util.shellQuote(key))
    }
  }

  // Each workspace's layout is read once and cached. It only changes through
  // the layout commands, which ask the dock to refresh, or a config reload.
  property var modes: ({})
  property var pendingModes: []
  property int modeGeneration: 0
  property int modeProcWorkspace: -1
  property int modeProcGeneration: 0

  function isFloating(workspaceId) {
    return root.modes[workspaceId] === "floating"
  }

  function readMode(workspaceId) {
    if (!(workspaceId >= 1) || root.modes[workspaceId] !== undefined) return
    if (root.pendingModes.indexOf(workspaceId) === -1) root.pendingModes.push(workspaceId)
    root.readNextMode()
  }

  function readNextMode() {
    if (modeProc.running || root.pendingModes.length === 0) return
    root.modeProcWorkspace = root.pendingModes.shift()
    root.modeProcGeneration = root.modeGeneration
    modeProc.command = ["omarchy-hyprland-workspace-layout-current", String(root.modeProcWorkspace)]
    modeProc.running = true
  }

  function refresh() {
    root.modes = ({})
    root.pendingModes = []
    root.modeGeneration++
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].activeWorkspace) root.readMode(monitors[i].activeWorkspace.id)
    }
    // Read the rest ahead of time, so the dock shows or hides the moment the
    // user switches to one.
    var workspaces = Hyprland.workspaces.values
    for (var j = 0; j < workspaces.length; j++) root.readMode(workspaces[j].id)
  }

  Component.onCompleted: {
    refresh()
    syncItemModel()
    sharpIconScan.running = true
    refreshDownloads()
    reportSnapReserve()
    reserveRetry.restart()
  }

  Process {
    id: modeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var mode = text.trim()
        // A read that started before a refresh may predate the change.
        if (!mode || root.modeProcGeneration !== root.modeGeneration) return
        var next = Object.assign({}, root.modes)
        next[root.modeProcWorkspace] = mode
        root.modes = next
      }
    }
    // Deferred: the process still reports running while it signals exit.
    onExited: Qt.callLater(root.readNextMode)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      // Borderless is global: windows that open on, or move to, a floating
      // workspace follow it. The helper only runs while it is switched on.
      if (name === "openwindow" || name === "movewindowv2") {
        var fields = String(event.data || "").split(",")
        var address = fields[0]
        if (/^[0-9a-fA-F]+$/.test(address)) {
          if (name === "movewindowv2" && DockModel.isMinimizedWorkspace(fields.slice(2).join(","))) root.onMinimized(address)
          else root.applyBorders("0x" + address.replace(/^0x/, ""))
        }
      }
      if (name === "configreloaded") {
        root.refresh()
        root.reportSnapReserve()
        reserveRetry.restart()
      }
      // Hyprland's window and workspace lists do not follow fullscreen on
      // their own.
      else if (name === "fullscreen") {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      }
    }
  }

  ShellIpc {
    target: "omarchy.dock"

    // The layout commands call this after changing a workspace's mode.
    function refresh(): void {
      root.refresh()
      root.applyBorders("")
    }
    function apps(): void { appGrid.toggle() }
    // Exposé: the three-finger swipe up toggles it, down leaves it.
    function expose(): void { root.toggleExpose() }
    function exposeClose(): void { root.closeExpose() }
    // Called by the Hyprland hook after Alt+Tab, with the new active
    // window's outer rectangle in global logical coordinates.
    function focusGlow(x: string, y: string, width: string, height: string, radius: string): void {
      var gx = parseInt(x), gy = parseInt(y), gw = parseInt(width), gh = parseInt(height)
      if (isNaN(gx) || isNaN(gy) || !(gw > 0) || !(gh > 0)) return
      var dock = root.dockAt(gx + gw / 2, gy + gh / 2)
      if (dock) dock.focusGlow(Qt.rect(gx, gy, gw, gh), parseInt(radius) || 0)
    }
    // What a click on a minimized window's slot does; also for scripts.
    function restoreMinimized(address: string): void {
      var window = root.minimizedFor(address)
      if (window) root.bringForward({ address: "0x" + window.address, minimized: true, toplevel: window.toplevel })
    }
    // The snap plugin hands over Super+clicks on the dock, in global logical
    // coordinates: Hyprland keeps them for its window drag otherwise.
    function superClick(x: string, y: string): void {
      var gx = parseInt(x), gy = parseInt(y)
      if (isNaN(gx) || isNaN(gy)) return
      var windows = docks.instances
      for (var i = 0; i < windows.length; i++) {
        var screen = windows[i].screen
        if (gx >= screen.x && gx < screen.x + screen.width && gy >= screen.y && gy < screen.y + screen.height) {
          windows[i].superClick(gx - screen.x, gy - screen.y)
          return
        }
      }
    }
    function downloads(): void {
      var monitor = Hyprland.focusedMonitor
      var windows = docks.instances
      for (var i = 0; i < windows.length; i++) {
        if (windows[i].monitor === monitor) windows[i].toggleDownloads()
      }
    }
  }

  // An app dragged out of the app grid: the grid holds the pointer and
  // reports where it is, and the dock on that screen shows where it would land.
  function dockOn(screen) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) return windows[i]
    }
    return null
  }

  function moveExternalDrag(screen, x, y) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) windows[i].moveExternalDrag(x, y)
      else windows[i].endExternalDrag()
    }
  }

  function dropExternalDrag(screen, x, y, key) {
    var target = root.dockOn(screen)
    if (target) target.dropExternalDrag(x, y, key)
    root.endExternalDrag()
  }

  function endExternalDrag() {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) windows[i].endExternalDrag()
  }

  Variants {
    id: docks
    model: Quickshell.screens

    delegate: Component {
      DockWindow {
        required property var modelData

        screen: modelData
        dock: root
      }
    }
  }

  AppGrid {
    id: appGrid
    appLibrary: root.appLibrary
    dock: root
  }
}
