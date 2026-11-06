import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DockModel.js" as DockModel

// One screen's dock. It stays mapped and only hides its contents, so switching
// to a floating workspace does not wait on a fresh layer surface. While hidden the
// mask is empty and clicks fall through to the windows below.
PanelWindow {
  id: window
  // Right-to-left languages read this window mirrored.
  Binding { target: window.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
  Binding { target: window.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }


  property var dock: null
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  property bool downloadsOpen: false

  readonly property string position: dock ? dock.position : "bottom"
  readonly property bool vertical: dock ? dock.vertical : false
  readonly property var monitor: Hyprland.monitorFor(screen)
  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property int workspaceId: workspace ? workspace.id : -1
  // The most fullscreen window on the workspace, as Hyprland counts it: 1 is
  // maximized, and 2 or 3 fullscreen.
  readonly property int fullscreenMode: {
    var mode = 0
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel.workspace || toplevel.workspace.id !== workspaceId) continue
      var ipc = toplevel.lastIpcObject
      mode = Math.max(mode, ipc && ipc.fullscreen ? ipc.fullscreen : 0)
    }
    return mode
  }
  readonly property bool shown: !!dock && dock.isFloating(workspaceId) && fullscreenMode < 2
  // With auto-hide on, the dock waits off screen until the pointer reaches its
  // edge, and stays while the pointer, a menu, or a drag still needs it. A
  // maximized window hides the dock the same way, so it can still be called up.
  readonly property bool autohide: !!dock && (dock.autohide || fullscreenMode === 1)
  property bool revealed: false
  readonly property bool menuOpen: menuItem !== null || settingsMenu || downloadsOpen
  readonly property bool tucked: autohide && !(revealed || menuOpen || dragging || insertIndex >= 0)
  readonly property bool contentShown: shown && !tucked

  readonly property int gap: Style.spacing.xs
  readonly property int iconSize: Math.round(36 * Style.fontScale)
  // Each app has a square slot with its icon in the middle, and the slots run
  // straight to the edge of the dock.
  readonly property int iconInset: Style.spacing.md
  readonly property int slotSize: iconSize + iconInset * 2
  // A pinned app that is not running is drawn faded.
  readonly property real idleOpacity: 0.7
  // Room inward of the dock for its menus: the tallest, the apps button's,
  // has five rows.
  readonly property int popupRoom: Math.max(Style.space(500), menu.height + gap * 2)
  // Icons pop away from the screen edge.
  readonly property int popOrigin: position === "top" ? Item.Top
    : position === "left" ? Item.Left
    : position === "right" ? Item.Right
    : Item.Bottom

  // The app being dragged along the dock, how far the pointer has taken it,
  // and the slot it would land in.
  property int dragIndex: -1
  property int dropIndex: -1
  property real dragOffset: 0
  readonly property bool dragging: dragIndex >= 0
  // Off while a drop resets the slots: they snap to where the reorder puts
  // them rather than sliding back from where they stepped aside. Set before
  // the drag state changes, so the slots never see the reset animated.
  property bool animateShifts: true
  // After a drop the slots have moved under a pointer that has not, so what
  // they think is hovered is stale until it moves again.
  property bool hoverStale: false
  property point dropPoint
  // Where an app dragged in from the app grid would land, or -1.
  property int insertIndex: -1

  // Where this window sits on its screen, which a point from the app grid's
  // fullscreen surface is given in: against its edge, clear of the space
  // other surfaces such as the bar reserve. Hyprland lists that space as
  // left, top, right, bottom.
  function origin() {
    var reserved = monitor && monitor.lastIpcObject && monitor.lastIpcObject.reserved ? monitor.lastIpcObject.reserved : [0, 0, 0, 0]
    var left = reserved[0] || 0, top = reserved[1] || 0, right = reserved[2] || 0, bottom = reserved[3] || 0
    var x = window.position === "right" ? screen.width - right - window.width : left
    var y = window.position === "bottom" ? screen.height - bottom - window.height : top
    return Qt.point(x, y)
  }

  // An app from the app grid lands where the pointer is, once it is over the
  // dock or close to it on the inward side.
  function moveExternalDrag(screenX, screenY) {
    var at = window.origin()
    var point = Qt.point(screenX - at.x - body.x, screenY - at.y - body.y)
    var reach = window.slotSize
    var along = window.vertical ? point.y : point.x
    var across = window.vertical ? point.x : point.y
    var length = window.vertical ? body.height : body.width
    var depth = window.vertical ? body.width : body.height
    var near = along >= -window.slotSize && along <= length + window.slotSize && across >= -reach && across <= depth + reach
    if (window.shown && window.autohide && near) window.revealed = true
    window.insertIndex = window.shown && near ? window.slotIndexAt(point) : -1
  }

  function dropExternalDrag(screenX, screenY, key) {
    window.moveExternalDrag(screenX, screenY)
    window.settleShifts()
    if (window.insertIndex >= 0 && key && window.dock) window.dock.pinAt(key, window.insertIndex)
    window.endExternalDrag()
  }

  function endExternalDrag() {
    window.insertIndex = -1
    if (window.autohide) hideTimer.restart()
  }

  // A Super+click on the dock, in screen coordinates: opens a new window of
  // the app under the pointer. The apps and downloads buttons act as clicked.
  function superClick(screenX, screenY) {
    if (!window.contentShown || !window.dock) return
    var at = window.origin()
    var point = Qt.point(screenX - at.x - body.x, screenY - at.y - body.y)
    var along = window.vertical ? point.y : point.x
    var across = window.vertical ? point.x : point.y
    var depth = window.vertical ? body.width : body.height
    if (across < 0 || across > depth) return
    var slot = Math.floor(along / window.slotSize)
    var count = window.dock.itemModel.count
    var minimized = minimizedRepeater.count
    if (slot !== count + minimized + 1) window.closeMenu()
    if (slot === 0) window.dock.openApps()
    else if (slot >= 1 && slot <= count) window.dock.newWindow(window.dock.itemFor(window.dock.itemModel.get(slot - 1).key))
    else if (slot > count && slot <= count + minimized) minimizedRepeater.itemAt(slot - count - 1).restore()
    else if (slot === count + minimized + 1) window.toggleDownloads()
  }

  // The slot a point along the dock falls before, counting from the first app.
  function slotIndexAt(point) {
    var along = window.vertical ? point.y : point.x
    var first = window.slotSize
    var count = window.dock ? window.dock.itemModel.count : 0
    return Math.max(0, Math.min(count, Math.round((along - first) / window.slotSize)))
  }
  property var menuItem: null
  property Item menuSlot: null
  // The apps button's menu: where the dock sits and whether it hides.
  property bool settingsMenu: false

  onWorkspaceIdChanged: if (dock) dock.readMode(workspaceId)
  onShownChanged: {
    if (shown) return
    closeMenu()
    window.revealed = false
  }
  Component.onCompleted: if (dock) dock.readMode(workspaceId)

  function openMenu(item, slot) {
    window.downloadsOpen = false
    window.settingsMenu = false
    window.menuItem = item
    window.menuSlot = slot
  }

  function openSettingsMenu(slot) {
    window.downloadsOpen = false
    window.menuItem = null
    window.settingsMenu = true
    window.menuSlot = slot
  }

  function settleShifts() {
    window.animateShifts = false
    Qt.callLater(function() { window.animateShifts = true })
  }

  function endDrag() {
    window.settleShifts()
    window.hoverStale = true
    window.dragIndex = -1
    window.dropIndex = -1
    window.dragOffset = 0
  }

  function closeMenu() {
    window.downloadsOpen = false
    window.menuItem = null
    window.settingsMenu = false
    window.menuSlot = null
    if (window.autohide) hideTimer.restart()
  }

  function toggleDownloads() {
    var wasOpen = window.downloadsOpen
    window.closeMenu()
    window.downloadsOpen = !wasOpen
    if (window.downloadsOpen) {
      window.revealed = true
      window.dock.refreshDownloads()
    }
  }

  // Places the menu inward of the dock, centered on a slot.
  function popupX(slot, popup) {
    if (!slot) return 0
    var center = slot.mapToItem(window.contentItem, slot.width / 2, 0).x
    if (window.position === "left") return body.x + body.width + window.gap
    if (window.position === "right") return body.x - window.gap - popup.width
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, center - popup.width / 2))
  }

  function popupY(slot, popup) {
    if (!slot) return 0
    var center = slot.mapToItem(window.contentItem, 0, slot.height / 2).y
    if (window.position === "top") return body.y + body.height + window.gap
    if (window.position === "bottom") return body.y - window.gap - popup.height
    return Math.max(window.gap, Math.min(window.height - popup.height - window.gap, center - popup.height / 2))
  }

  visible: !remapGuard.remapping
  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Kept clear of the bar's reserved edge, without reserving one of its own:
  // floating windows go where they are put.
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0

  anchors {
    top: window.position !== "bottom"
    bottom: window.position !== "top"
    left: window.position !== "right"
    right: window.position !== "left"
  }

  implicitWidth: window.vertical ? window.gap + window.slotSize + window.popupRoom : 0
  implicitHeight: window.vertical ? 0 : window.gap + window.slotSize + window.popupRoom

  mask: Region {
    item: window.contentShown ? body : null

    Region { item: window.shown && window.autohide ? edgeTrigger : null }
    Region { item: menu.visible ? menu : null }
    Region { item: downloadsFan.visible ? downloadsFan : null }
  }

  onAutohideChanged: window.revealed = false

  Timer {
    id: hideTimer
    // Long enough to cross a gap between the edge and the icons, no longer.
    interval: 150
    onTriggered: {
      if (!bodyHover.hovered && !edgeHover.hovered && !window.menuOpen && !window.dragging) window.revealed = false
    }
  }

  // The strip along the screen edge that brings an auto-hidden dock back.
  Item {
    id: edgeTrigger

    readonly property int depth: window.gap + Style.spacing.xxs

    x: window.position === "left" ? 0 : window.position === "right" ? window.width - depth : body.x
    y: window.position === "top" ? 0 : window.position === "bottom" ? window.height - depth : body.y
    width: window.vertical ? depth : body.width
    height: window.vertical ? body.height : depth

    HoverHandler {
      id: edgeHover
      onHoveredChanged: {
        if (hovered) window.revealed = true
        else hideTimer.restart()
      }
    }
  }

  ScreenMoveRemap {
    id: remapGuard
    window: window
  }

  HyprlandFocusGrab {
    active: window.menuOpen
    windows: [window]
    onCleared: window.closeMenu()
  }

  Item {
    id: body

    // The strip keeps its order in every language, like the bar: drags and
    // drops reckon slots along x from the first app. Only the menu mirrors.
    LayoutMirroring.enabled: false
    LayoutMirroring.childrenInherit: true

    width: slots.implicitWidth
    height: slots.implicitHeight
    // How far the dock is tucked past its edge. Auto-hide slides it, but only
    // while the dock is on screen: arriving on a floating workspace shows it
    // where it belongs at once.
    property real tuck: window.tucked ? window.slotSize + window.gap : 0

    // Tucking away is quicker than coming back. A gentler curve than
    // Style.easeOut, which crosses the short slide in a frame or two.
    Behavior on tuck {
      id: tuckMotion
      enabled: window.shown
      NumberAnimation {
        duration: Style.duration(tuckMotion.targetValue > 0 ? 120 : 180)
        easing.type: Easing.OutCubic
      }
    }

    x: window.position === "left" ? window.gap - tuck
      : window.position === "right" ? window.width - width - window.gap + tuck
      : Math.round((window.width - width) / 2)
    y: window.position === "top" ? window.gap - tuck
      : window.position === "bottom" ? window.height - height - window.gap + tuck
      : Math.round((window.height - height) / 2)
    // Switching between tiled and floating workspaces shows and hides the dock
    // at once, with nothing to watch in between. Hidden by opacity rather than
    // visibility, so the icons keep their textures and are drawn on the first
    // frame back instead of being uploaded again.
    opacity: window.shown ? 1 : 0

    HoverHandler {
      id: bodyHover
      onHoveredChanged: if (!hovered && window.autohide) hideTimer.restart()
      // Only a real move clears it: the release itself reports the pointer too.
      onPointChanged: {
        if (!window.hoverStale || window.dragging) return
        var at = point.position
        if (Math.hypot(at.x - window.dropPoint.x, at.y - window.dropPoint.y) > Style.space(4)) window.hoverStale = false
      }
    }

    Grid {
      id: slots
      anchors.centerIn: parent
      columns: window.vertical ? 1 : appRepeater.count + minimizedRepeater.count + 2

      AppsSlot {}

      Repeater {
        id: appRepeater
        model: window.dock ? window.dock.itemModel : null

        delegate: AppSlot {}
      }

      // Minimized windows, oldest first, between the apps and Downloads.
      Repeater {
        id: minimizedRepeater
        model: window.dock ? window.dock.minimizedModel : null
        delegate: MinimizedSlot {}
      }

      Slot {
        id: downloadsSlot
        mouse.onClicked: function(event) {
          if (event.button === Qt.RightButton && window.dock.downloadsUri) {
            Quickshell.execDetached(["gio", "open", window.dock.downloadsUri])
            window.closeMenu()
            return
          }
          window.toggleDownloads()
        }
        DockSeparator { visible: minimizedRepeater.count === 0 }
        Image {
          anchors.centerIn: parent
          width: window.iconSize; height: window.iconSize
          sourceSize: Qt.size(width * 2, height * 2)
          source: Quickshell.iconPath("folder-download", true)
          fillMode: Image.PreserveAspectFit
          scale: downloadsSlot.hovered || window.downloadsOpen ? 1.15 : 1
          Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
        }
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "↓"
          font.pixelSize: window.iconSize * 0.55
          color: Commons.Color.bar.text
          visible: !Quickshell.iconPath("folder-download", true)
        }
      }
    }
  }

  // The line between the apps and what follows them: minimized windows and
  // Downloads. It sits on the leading edge of the first of those slots.
  component DockSeparator: Rectangle {
    x: window.vertical ? window.iconInset : 0
    y: window.vertical ? 0 : window.iconInset
    width: window.vertical ? window.iconSize : 1
    height: window.vertical ? 1 : window.iconSize
    color: Commons.Color.bar.text
    opacity: 0.25
  }

  // A minimized window: a snapshot of it, with its app's icon on the corner.
  // A click brings it back out, through the genie.
  component MinimizedSlot: Slot {
    id: minSlot
    required property int index
    required property string address
    readonly property var modelData: window.dock ? window.dock.minimizedFor(address) : null
    readonly property bool pouring: window.genieAddress === address

    DockSeparator { visible: minSlot.index === 0 }

    function restore() {
      if (!minSlot.modelData) return
      window.closeMenu()
      window.dock.bringForward({ address: "0x" + minSlot.address, minimized: true, toplevel: minSlot.modelData.toplevel })
    }

    mouse.onClicked: function(event) {
      if (!minSlot.modelData) return
      if (event.button === Qt.RightButton) {
        var app = window.dock.itemFor(minSlot.modelData.key)
        if (app) window.openMenu(app, minSlot)
        return
      }
      minSlot.restore()
    }

    Item {
      id: thumbBox
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      scale: minSlot.hovered ? 1.15 : 1
      transformOrigin: window.popOrigin
      opacity: minSlot.pouring ? 0 : 1
      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: Style.duration(140) } }

      ScreencopyView {
        id: thumb
        readonly property real aspect: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 1.6
        anchors.centerIn: parent
        width: aspect >= 1 ? parent.width : parent.height * aspect
        height: aspect >= 1 ? parent.width / aspect : parent.height
        captureSource: minSlot.modelData ? minSlot.modelData.toplevel : null
        live: false
      }
      Rectangle {
        anchors.fill: thumb
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(Commons.Color.bar.text.r, Commons.Color.bar.text.g, Commons.Color.bar.text.b, 0.25)
        radius: 2
      }
      Image {
        width: Math.round(window.iconSize * 0.45); height: width
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: -Math.round(width * 0.2); anchors.bottomMargin: -Math.round(width * 0.2)
        sourceSize: Qt.size(width * 2, height * 2)
        source: window.dock && minSlot.modelData ? window.dock.iconFor({ key: minSlot.modelData.key }) : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
      }
    }
  }

  // Exposé, on this screen.
  ExposeOverlay {
    id: exposeOverlay
    screen: window.screen
    onFinished: function(address) {
      if (address && window.dock) window.dock.bringForward({ address: address, minimized: false })
    }
    onCloseWindow: function(address) {
      var target = String(address || "")
      if (target.indexOf("0x") !== 0) target = "0x" + target
      if (/^0x[0-9a-fA-F]+$/.test(target))
        Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.window.close({ window = \"address:" + target + "\" })"])
    }
  }
  function openExpose(list) {
    window.closeMenu()
    exposeOverlay.show(list)
  }
  function closeExpose() { exposeOverlay.leave("") }
  function exposeOpen() { return exposeOverlay.open }

  // The glow around the window Alt+Tab focused, on this screen.
  FocusGlow {
    id: focusGlowOverlay
    screen: window.screen
  }
  function focusGlow(globalRect, radius) {
    focusGlowOverlay.play(window.toScreen(globalRect), radius)
  }

  // The genie into and out of the dock, on this screen.
  property string genieAddress: ""
  GenieOverlay {
    id: genie
    screen: window.screen
    edge: window.position
  }

  // A slot's rectangle in screen coordinates, as the genie needs it.
  function slotScreenRect(slot) {
    if (!slot) return null
    var at = window.origin()
    return Qt.rect(at.x + body.x + slots.x + slot.x + window.iconInset, at.y + body.y + slots.y + slot.y + window.iconInset,
                   window.iconSize, window.iconSize)
  }
  function minimizedSlotRect(address) {
    for (var i = 0; i < minimizedRepeater.count; i++) {
      var slot = minimizedRepeater.itemAt(i)
      if (slot && slot.address === address) return window.slotScreenRect(slot)
    }
    return window.slotScreenRect(downloadsSlot)
  }
  function toScreen(globalRect) {
    return Qt.rect(globalRect.x - window.screen.x, globalRect.y - window.screen.y, globalRect.width, globalRect.height)
  }

  function genieMinimize(toplevel, address, globalRect) {
    if (!window.shown) return
    window.revealed = true
    window.genieAddress = address
    genie.play(toplevel, window.toScreen(globalRect), function() { return window.minimizedSlotRect(address) }, false, function() {
      window.genieAddress = ""
      if (window.autohide) hideTimer.restart()
    })
  }

  function genieRestore(toplevel, address, globalRect, done) {
    if (!window.shown) { done(); return }
    window.genieAddress = address
    var slotRect = window.minimizedSlotRect(address)
    genie.play(toplevel, window.toScreen(globalRect), function() { return slotRect }, true, function() {
      window.genieAddress = ""
      done()
    })
  }

  component Slot: Item {
    id: slot

    // Only the dragged icon is lifted while a drag is on; none of the others
    // pop as it passes over them.
    property bool hovered: mouse.containsMouse && !window.hoverStale && !window.dragging
    property bool pressed: mouse.pressed
    property alias mouse: mouse

    width: window.slotSize
    height: window.slotSize

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    }
  }

  component AppsSlot: Slot {
    id: appsSlot

    property real displayedShift: window.insertIndex >= 0 ? -window.slotSize / 2 : 0

    Behavior on displayedShift {
      enabled: window.animateShifts
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    transform: Translate {
      x: window.vertical ? 0 : appsSlot.displayedShift
      y: window.vertical ? appsSlot.displayedShift : 0
    }

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openSettingsMenu(appsSlot)
        return
      }
      window.closeMenu()
      if (window.dock) window.dock.openApps()
    }

    // A grid of app squares reads as "all apps" in any icon theme. Drawn
    // rather than taken from a font, so its edges stay crisp on the
    // transparent dock and it fills its slot like the app icons beside it.
    Item {
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      scale: appsSlot.hovered ? 1.15 : 1
      transformOrigin: window.popOrigin

      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      Grid {
        readonly property int square: Math.round(window.iconSize * 0.22)

        anchors.centerIn: parent
        columns: 3
        spacing: Math.round(window.iconSize * 0.1)

        Repeater {
          model: 9

          delegate: Rectangle {
            width: parent.square
            height: parent.square
            radius: Math.max(1, Math.round(parent.square * 0.2))
            color: Commons.Color.bar.text
          }
        }
      }
    }
  }

  component AppSlot: Slot {
    id: appSlot

    required property int index
    required property string key
    readonly property var modelData: window.dock ? window.dock.itemFor(key) : null
    readonly property bool launching: !!window.dock && window.dock.isLaunching(key)
    readonly property bool lifted: window.dragIndex === index
    property point pressPoint
    property bool dragged: false
    readonly property int windowCount: modelData ? modelData.windows.length : 0
    property real pulse: 1

    // Slots between where the dragged app was and where it would land step
    // aside to make room; the dragged one follows the pointer.
    readonly property real shift: window.insertIndex >= 0 ? (index >= window.insertIndex ? 1 : -1) * window.slotSize / 2
      : !window.dragging ? 0
      : lifted ? window.dragOffset
      : (window.dragIndex < index && index <= window.dropIndex) ? -window.slotSize
      : (window.dropIndex <= index && index < window.dragIndex) ? window.slotSize
      : 0
    property real displayedShift: shift

    // Only while dragging: once the drop reorders the slots, they are already
    // where they were shown.
    Behavior on displayedShift {
      enabled: window.animateShifts && ((window.dragging && !appSlot.lifted) || window.insertIndex >= 0)
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    z: lifted ? 1 : 0

    // The slot, and the pointer handling in it, stays where it is; only the
    // icon moves. Reading the pointer through a slot that moves with it would
    // feed each move back into the next.
    function bodyPoint(event) {
      return appSlot.mapToItem(body, event.x, event.y)
    }

    mouse.onPressed: function(event) {
      appSlot.dragged = false
      if (event.button === Qt.LeftButton) appSlot.pressPoint = appSlot.bodyPoint(event)
    }

    mouse.onPositionChanged: function(event) {
      if (!(appSlot.mouse.pressedButtons & Qt.LeftButton)) return
      var point = appSlot.bodyPoint(event)
      var delta = window.vertical ? point.y - appSlot.pressPoint.y : point.x - appSlot.pressPoint.x
      // A press that wanders is a drag in the making, not a click.
      if (Math.hypot(point.x - appSlot.pressPoint.x, point.y - appSlot.pressPoint.y) > Style.space(4)) appSlot.dragged = true
      if (!window.dragging) {
        if (Math.abs(delta) < Style.space(6)) return
        window.closeMenu()
        // The landing slot first: with the dragged slot set and no landing
        // slot yet, every slot before it would count as in between and step
        // aside for a moment.
        window.dropIndex = appSlot.index
        window.dragIndex = appSlot.index
      }
      if (!appSlot.lifted) return
      window.dragOffset = delta
      window.dropIndex = DockModel.dropIndex(appSlot.index, delta, window.slotSize, appRepeater.count)
    }

    mouse.onReleased: function(event) {
      if (!appSlot.lifted) return
      window.dropPoint = appSlot.mapToItem(body, event.x, event.y)
      var from = window.dragIndex
      var to = window.dropIndex
      appSlot.dragged = true
      window.endDrag()
      window.dock.moveItem(from, to)
    }

    mouse.onCanceled: if (appSlot.lifted) window.endDrag()

    mouse.onClicked: function(event) {
      // A drag ends in a release over the app, which is not a click on it.
      if (appSlot.dragged) {
        appSlot.dragged = false
        return
      }
      if (event.button === Qt.RightButton) {
        window.openMenu(appSlot.modelData, appSlot)
        return
      }
      window.closeMenu()
      if (event.button === Qt.MiddleButton || (event.button === Qt.LeftButton && (event.modifiers & Qt.MetaModifier))) window.dock.newWindow(appSlot.modelData)
      else window.dock.activate(appSlot.modelData)
    }

    // Running apps are drawn in full, pinned ones that are not running faded,
    // and one that is starting pulses between the two.
    Image {
      id: appIcon
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      sourceSize: Qt.size(window.iconSize * 2, window.iconSize * 2)
      source: window.dock && appSlot.modelData ? window.dock.iconFor(appSlot.modelData) : ""
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      opacity: appSlot.launching ? appSlot.pulse : (appSlot.windowCount > 0 ? 1 : window.idleOpacity)
      transform: Translate {
        x: window.vertical ? 0 : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : 0
      }
      scale: appSlot.lifted || appSlot.hovered ? 1.15 : 1
      transformOrigin: window.popOrigin

      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }

    Rectangle {
      visible: appIcon.status === Image.Error || appIcon.status === Image.Null
      x: window.iconInset + (window.vertical ? 0 : appSlot.displayedShift)
      y: window.iconInset + (window.vertical ? appSlot.displayedShift : 0)
      width: window.iconSize; height: window.iconSize
      radius: Style.cornerRadius
      color: Commons.Color.popups.background
      border.width: Style.normalBorderWidth
      border.color: Commons.Color.bar.text
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: appSlot.modelData ? String(appSlot.modelData.key).slice(0, 1).toUpperCase() : "□"
        color: Commons.Color.bar.text
        font.pixelSize: window.iconSize * 0.55
      }
    }

    // With animations off it holds still rather than spinning through
    // zero-length steps.
    SequentialAnimation {
      running: appSlot.launching && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) appSlot.pulse = 1

      NumberAnimation { target: appSlot; property: "pulse"; from: 1; to: window.idleOpacity; duration: Style.duration(500); easing.type: Easing.InOutSine }
      NumberAnimation { target: appSlot; property: "pulse"; to: 1; duration: Style.duration(500); easing.type: Easing.InOutSine }
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      y: window.iconInset + window.iconSize + Style.space(3)
      spacing: Style.space(3)
      transform: Translate {
        x: window.vertical ? 0 : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : 0
      }
      Repeater {
        model: Math.min(appSlot.windowCount, 7)
        Rectangle { width: Style.space(4); height: width; radius: width / 2; color: Commons.Color.bar.text }
      }
      Text {
        visible: appSlot.windowCount > 7
        textFormat: Text.PlainText
        text: "+" + Commons.I18n.formatNumber(appSlot.windowCount - 7)
        font.pixelSize: Style.space(9)
        color: Commons.Color.bar.text
      }
    }
  }

  DownloadsFan {
    id: downloadsFan
    visible: window.contentShown && window.downloadsOpen
    dock: window.dock
    title: strings.t("downloads")
    openFolderText: strings.t("openFolder")
    emptyText: window.dock && window.dock.downloadsLoading ? strings.t("loading")
      : window.dock && window.dock.downloadsFailed ? strings.t("downloadError") : strings.t("empty")
    // The stack icon's center, from bindable positions so the fan follows the
    // icon whenever the dock grows, shrinks or slides (mapToItem would not).
    readonly property real slotCenterX: body.x + slots.x + downloadsSlot.x + downloadsSlot.width / 2
    // Wide enough for the labels to one side and the arc to the other.
    width: Math.min(Style.space(460), window.width - window.gap * 2)
    // Centered on the icon; only pushed aside where the screen edge forces it,
    // and the fan's own column still lines up with the icon then.
    x: window.vertical ? window.popupX(downloadsSlot, downloadsFan)
      : Math.round(Math.max(window.gap, Math.min(window.width - width - window.gap, slotCenterX - width / 2)))
    y: window.popupY(downloadsSlot, downloadsFan)
    fromTop: window.position === "top"
    pixelRatio: window.screen ? window.screen.devicePixelRatio : 1
    stackX: window.vertical ? width / 2 : slotCenterX - x
    onDismissed: window.closeMenu()
  }

  BorderSurface {
    id: menu

    readonly property var item: window.menuItem
    readonly property bool hasEntry: !!item && !!window.dock && !!window.dock.entryFor(item)
    readonly property bool running: !!item && item.windows.length > 0

    visible: window.contentShown && (!!item || window.settingsMenu)
    width: Math.max(Style.space(140), menuColumn.implicitWidth) + padding * 2
    height: menuColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, menu)
    y: window.popupY(window.menuSlot, menu)
    radius: Style.cornerRadius
    color: Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    Column {
      id: menuColumn
      x: menu.contentLeftInset
      y: menu.contentTopInset
      width: menu.width - menu.contentLeftInset - menu.contentRightInset

      Repeater {
        model: [["top", Commons.I18n.t("dock.positionTop")], ["bottom", Commons.I18n.t("dock.positionBottom")], ["left", Commons.I18n.t("dock.positionLeft")], ["right", Commons.I18n.t("dock.positionRight")]]

        delegate: MenuRow {
          required property var modelData

          visible: window.settingsMenu
          text: modelData[1]
          checked: window.position === modelData[0]
          onTriggered: Util.execDetached("omarchy-dock position " + modelData[0])
        }
      }

      MenuRow {
        visible: window.settingsMenu
        text: Commons.I18n.t("dock.autoHide")
        checked: window.autohide
        onTriggered: Util.execDetached("omarchy-dock autohide " + (window.autohide ? "off" : "on"))
      }

      MenuRow {
        visible: menu.hasEntry && menu.running
        text: Commons.I18n.t("dock.newWindow")
        onTriggered: window.dock.newWindow(menu.item)
      }

      Repeater {
        model: menu.item ? menu.item.windows : []
        delegate: MenuRow {
          required property var modelData
          text: (modelData.minimized ? "↗ " : "• ") + String(modelData.toplevel.title || menu.item.key)
          onTriggered: window.dock.bringForward(modelData)
        }
      }

      MenuRow {
        visible: menu.running && menu.item.windows.some(function(w) { return !w.minimized && w.workspaceId === window.workspaceId })
        text: strings.t("minimize")
        onTriggered: {
          var candidates = menu.item.windows.filter(function(w) { return !w.minimized && w.workspaceId === window.workspaceId })
          var chosen = candidates.find(function(w) { return w.toplevel.activated }) || candidates[0]
          if (chosen) window.dock.minimize(chosen)
        }
      }

      MenuRow {
        visible: menu.hasEntry
        text: menu.item && menu.item.pinned ? Commons.I18n.t("dock.removeFromDock") : Commons.I18n.t("dock.keepInDock")
        onTriggered: window.dock.setPinned(menu.item.key, !menu.item.pinned)
      }

      MenuRow {
        visible: menu.running
        text: Commons.I18n.t("dock.quit")
        onTriggered: window.dock.quit(menu.item)
      }
    }
  }

  component MenuRow: Rectangle {
    id: row

    property string text: ""
    property bool checked: false
    signal triggered()

    width: parent ? parent.width : 0
    height: visible ? Style.spacing.popupRowHeight : 0
    radius: Style.cornerRadius
    color: rowMouse.containsMouse ? Style.hoverFill : "transparent"

    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      width: row.width - Style.spacing.controlPaddingX * 2 - Style.space(20)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: row.text
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      visible: row.checked
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      text: "✓"
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        row.triggered()
        window.closeMenu()
      }
    }
  }
}
