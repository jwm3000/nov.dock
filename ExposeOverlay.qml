import QtQuick
import QtQuick.Effects
import QtQuick.Particles
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Exposé, after macOS: every floating window of the workspace, side by side.
//
// The windows seem to turn into the overview themselves. Each preview starts
// exactly over its window, titlebar included, stacked as the windows are,
// and only appears once every live preview has its first frame. Behind them
// the wallpaper takes the windows' place, so swapping the windows for their
// copies cannot be seen; the copies then fly into a grid that keeps their
// proportions and rough arrangement. The bar and the dock stay as they are.
//
// A click on a window brings it forward: it is raised at once, behind the
// wallpaper, so when Exposé is gone the windows are stacked as shown. The X
// in a window's titlebar closes that window with a particle burst while the
// others fill the gap. Esc, a click on the empty space or a three-finger
// swipe down leave.
PanelWindow {
  id: root

  // { address, title, icon, home (rect incl. titlebar, screen coordinates),
  //   bar (titlebar height), layer (stacking order, higher is in front), toplevel }
  property var windows: []
  // hyprbars' titlebar, as the theme has it.
  property var titlebar: ({ height: 0, color: "#353b44", text: "#d2d7da", textSize: 12 })
  // Screen areas that keep showing what is beneath: the bar and the dock.
  property var holes: []
  // The space the bar reserves on each edge (left, top, right, bottom).
  property var reserved: [0, 0, 0, 0]
  // Windows closed from Exposé leave the grid, bursting where they were
  // (frozen holds that last cell).
  property var gone: ({})
  property var frozen: ({})
  // 0 = windows where they are, 1 = laid out in the grid.
  property real progress: 0
  property bool open: false
  property bool shown: false
  property bool closing: false
  property int selected: -1
  property string chosenAddress: ""

  // A window was picked: raise it now, while the real windows are hidden.
  signal chose(string address)
  // Emitted once Exposé is gone.
  signal finished()
  // A window's X was pressed.
  signal closeWindow(string address)

  readonly property int margin: Math.round(Math.min(width, height) * 0.05)
  readonly property int gap: Style.space(34)
  readonly property int titleHeight: Style.space(36)
  readonly property int topRoom: Style.space(56)
  readonly property var layout: root.computeLayout(root.windows, root.gone,
    Qt.rect(root.margin, root.topRoom, root.width - root.margin * 2, root.height - root.topRoom - root.margin))

  // Mapped from the moment a swipe begins (prepared), so the surface, the
  // window list and the first frames of the previews are ready by the time
  // the fingers have moved far enough to show anything.
  visible: root.open || root.closing || root.prepared
  color: "transparent"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "nov-dock-expose"
  WlrLayershell.keyboardFocus: root.open && !root.closing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }
  // The bar and the dock take their own clicks.
  // While only prepared, it takes no input at all.
  mask: Region {
    item: root.open ? hitArea : null
    Region { item: holeItems.count > 0 ? holeItems.itemAt(0) : null; intersection: Intersection.Subtract }
    Region { item: holeItems.count > 1 ? holeItems.itemAt(1) : null; intersection: Intersection.Subtract }
    Region { item: holeItems.count > 2 ? holeItems.itemAt(2) : null; intersection: Intersection.Subtract }
  }
  Item { id: hitArea; anchors.fill: parent }


  // The motion: one critically damped spring moves the progress toward its
  // target, frame by frame in step with the display. The fingers move the
  // target while they are down (the spring smooths their uneven events);
  // lifting them only changes the target, so their speed carries straight
  // into the settling, and opening or leaving by key or click use the same
  // spring. Stiffer while following the fingers, a touch softer settling.
  property real target: 0
  property real velocity: 0
  property bool moving: false
  FrameAnimation {
    running: root.moving && root.visible
    onTriggered: root.step(frameTime)
  }
  function moveTo(value) {
    root.target = Math.max(0, Math.min(1, value))
    if (Style.reduceMotion) {
      root.progress = root.target
      root.velocity = 0
      root.settled()
      return
    }
    root.moving = true
  }
  function step(dt) {
    var t = Math.min(Math.max(dt, 0.001), 1 / 30)
    var omega = root.gestureActive ? 40 : 26
    var accel = -omega * omega * (root.progress - root.target) - 2 * omega * root.velocity
    root.velocity += accel * t
    var next = root.progress + root.velocity * t
    if (next < 0 || next > 1) { next = Math.max(0, Math.min(1, next)); root.velocity = 0 }
    root.progress = next
    if (Math.abs(root.progress - root.target) < 0.0008 && Math.abs(root.velocity) < 0.03) {
      root.progress = root.target
      root.velocity = 0
      root.moving = false
      root.settled()
    }
  }
  function settled() {
    if (root.closing && root.target === 0) root.finish()
  }

  // Driven by the three-finger swipe: while the fingers are down they set
  // the target (from where Exposé stood when they touched down). On lifting,
  // how far they went decides: a third of the way or more completes it, less
  // goes back to where the swipe started. A cancelled swipe goes back too.
  readonly property real commitDistance: 0.35
  property bool gestureActive: false
  property bool gestureEnded: false
  property bool gestureOpens: false
  property real gestureFrom: 0
  property real gestureValue: 0
  property bool interactive: false
  property bool prepared: false

  function gestureBegin() {
    root.gestureActive = true
    root.gestureEnded = false
    root.gestureFrom = root.open && root.shown && !root.closing ? root.target : 0
    root.gestureValue = root.gestureFrom
    gestureIdle.restart()
  }
  // Should the end of a swipe never arrive, it settles once the fingers
  // have been still for a moment, so it can never stay halfway.
  Timer { id: gestureIdle; interval: 700; onTriggered: root.gestureEnd(false) }
  function gestureMove(travel) {
    if (!root.gestureActive) return
    root.gestureValue = Math.max(0, Math.min(1, root.gestureFrom + travel))
    gestureIdle.restart()
    if (root.open && root.shown && !root.closing) root.moveTo(root.gestureValue)
  }
  function gestureEnd(cancelled) {
    if (!root.gestureActive) return
    root.gestureActive = false
    gestureIdle.stop()
    var fromOpen = root.gestureFrom >= 0.5
    var opens = cancelled ? fromOpen
      : (fromOpen ? root.gestureValue > 1 - root.commitDistance : root.gestureValue >= root.commitDistance)
    if (root.open && root.shown && !root.closing) {
      if (opens) root.moveTo(1)
      else root.leave("")
    } else if (root.open) {
      // Shown in a moment: settle then.
      root.gestureEnded = true
      root.gestureOpens = opens
    } else if (!opens) {
      root.discard()
    } else {
      root.gestureEnded = true
      root.gestureOpens = true
    }
  }

  function setUp(list, bar, keep) {
    root.titlebar = bar || root.titlebar
    root.holes = keep || []
    root.windows = list
    root.gone = ({})
    root.frozen = ({})
    root.selected = -1
    root.chosenAddress = ""
    root.progress = 0
    root.target = 0
    root.velocity = 0
    root.moving = false
    root.shown = false
  }

  // A swipe has begun: get everything ready, invisibly.
  function prepare(list, bar, keep) {
    if (root.open || root.closing || !list || list.length === 0) return
    root.setUp(list, bar, keep)
    root.prepared = true
  }
  // The swipe went nowhere: let it go again.
  function discard() {
    if (root.open || root.closing) return
    root.prepared = false
    root.windows = []
  }

  function show(list, bar, keep, gesture) {
    if (root.open || root.closing) return
    var usePrepared = (!list || list.length === 0) && root.prepared
    if (!usePrepared && (!list || list.length === 0)) return
    // A swipe that already ended short of opening opens nothing.
    if (gesture && root.gestureEnded && !root.gestureOpens) { root.gestureEnded = false; root.discard(); return }
    root.interactive = gesture === true
    if (!usePrepared) root.setUp(list, bar, keep)
    root.prepared = false
    root.open = true
    keys.forceActiveFocus()
    if (root.previewsReady()) root.reveal()
    else { readyCheck.restart(); readyGuard.restart() }
  }

  // Waits for every preview's first frame (or a short moment at most), so
  // the copies never show up empty over the real windows.
  function previewsReady() {
    for (var i = 0; i < tiles.count; i++) {
      var tile = tiles.itemAt(i)
      if (tile && !tile.ready) return false
    }
    return tiles.count === root.windows.length
  }
  // Starts at the windows themselves and lets the spring take it from there:
  // to the fingers while a swipe is on, else open, even when a fast swipe
  // has already ended, so the flight is always seen.
  function reveal() {
    if (root.shown || !root.open) return
    readyCheck.stop()
    readyGuard.stop()
    root.shown = true
    root.progress = 0
    root.velocity = 0
    if (root.interactive && root.gestureEnded) {
      root.gestureEnded = false
      if (root.gestureOpens) root.moveTo(1)
      else root.leave("")
    } else if (root.interactive && root.gestureActive) {
      root.moveTo(root.gestureValue)
    } else {
      root.moveTo(1)
    }
  }
  Timer { id: readyCheck; interval: 8; repeat: true; onTriggered: if (root.previewsReady()) root.reveal() }
  Timer { id: readyGuard; interval: 120; onTriggered: root.reveal() }

  // Leaves Exposé; with an address, that window comes forward on top.
  function leave(address) {
    // Still loading when asked to go: open nothing.
    if (root.open && !root.shown && !root.closing) { root.finish(); return }
    if (!root.open || root.closing) return
    root.chosenAddress = address || ""
    // Closing first: Exposé gives up the keyboard, so the picked window can
    // take the focus. Raised a moment later, during the flight back, it is
    // in front and focused by the time Exposé is gone.
    root.closing = true
    if (root.chosenAddress) chooseTimer.restart()
    readyCheck.stop()
    readyGuard.stop()
    root.moveTo(0)
  }

  Timer { id: chooseTimer; interval: 60; onTriggered: if (root.chosenAddress) root.chose(root.chosenAddress) }

  function finish() {
    root.open = false
    root.closing = false
    root.shown = false
    root.prepared = false
    root.moving = false
    root.windows = []
    root.gone = ({})
    root.frozen = ({})
    root.finished()
  }

  function alive(index) { return index >= 0 && index < root.windows.length && !root.gone[index] }
  function aliveCount() {
    var n = 0
    for (var i = 0; i < root.windows.length; i++) if (!root.gone[i]) n++
    return n
  }

  // Closes one window from Exposé: it bursts, the grid closes the gap, and
  // Hyprland closes the window itself.
  function dismiss(index) {
    if (!root.alive(index) || root.closing || !root.shown) return
    var cells = Object.assign({}, root.frozen)
    cells[index] = root.layout[index]
    root.frozen = cells
    var next = Object.assign({}, root.gone)
    next[index] = true
    root.gone = next
    root.closeWindow(root.windows[index].address)
    if (root.selected === index) root.selected = -1
    if (root.aliveCount() === 0) leaveTimer.restart()
  }
  // Long enough for the last burst to be seen.
  Timer { id: leaveTimer; interval: Style.duration(520); onTriggered: root.leave("") }


  // The grid. Rows are tried from one up; each window is scaled to fit its
  // cell (never above its own size), and the row count that shows the most
  // of the windows wins. Windows fill the rows in reading order of where
  // they are on screen, and each row is centered. Closed windows get none.
  function computeLayout(list, closed, area) {
    var indices = []
    for (var i = 0; i < (list ? list.length : 0); i++) if (!closed[i]) indices.push(i)
    var n = indices.length
    var rects = new Array(list ? list.length : 0)
    if (n === 0 || area.width <= 0 || area.height <= 0) return rects
    indices.sort(function(a, b) {
      var A = list[a].home, B = list[b].home
      return (A.y + A.height / 2) - (B.y + B.height / 2)
    })
    var best = null
    for (var rows = 1; rows <= n; rows++) {
      var cols = Math.ceil(n / rows)
      var cellW = (area.width - (cols - 1) * root.gap) / cols
      var cellH = (area.height - (rows - 1) * root.gap) / rows - root.titleHeight
      if (cellW <= 20 || cellH <= 20) continue
      var shownArea = 0
      for (var k = 0; k < n; k++) {
        var h = list[indices[k]].home
        var s = Math.min(cellW / h.width, cellH / h.height, 1)
        shownArea += h.width * s * h.height * s
      }
      if (!best || shownArea > best.shown) best = { rows: rows, cols: cols, cellW: cellW, cellH: cellH, shown: shownArea }
    }
    if (!best) return rects
    var used = Math.ceil(n / best.cols)
    var blockH = used * (best.cellH + root.titleHeight) + (used - 1) * root.gap
    var top = area.y + (area.height - blockH) / 2
    for (var r = 0; r < used; r++) {
      var row = indices.slice(r * best.cols, (r + 1) * best.cols)
      row.sort(function(a, b) { return (list[a].home.x + list[a].home.width / 2) - (list[b].home.x + list[b].home.width / 2) })
      var sizes = row.map(function(j) {
        var h = list[j].home
        var s = Math.min(best.cellW / h.width, best.cellH / h.height, 1)
        return { w: h.width * s, h: h.height * s }
      })
      var rowW = sizes.reduce(function(sum, z) { return sum + z.w }, 0) + (row.length - 1) * root.gap
      var x = area.x + (area.width - rowW) / 2
      var y = top + r * (best.cellH + root.titleHeight + root.gap)
      for (var m = 0; m < row.length; m++) {
        rects[row[m]] = Qt.rect(x, y + (best.cellH - sizes[m].h) / 2, sizes[m].w, sizes[m].h)
        x += sizes[m].w + root.gap
      }
    }
    return rects
  }

  // Keyboard: arrows pick, Enter opens, Delete closes, Esc leaves.
  function moveSelection(dx, dy) {
    if (root.aliveCount() === 0) return
    if (!root.alive(root.selected)) {
      for (var f = 0; f < root.windows.length; f++) if (root.alive(f)) { root.selected = f; return }
    }
    var from = root.layout[root.selected]
    var cx = from.x + from.width / 2, cy = from.y + from.height / 2
    var bestIndex = -1, bestScore = Infinity
    for (var i = 0; i < root.layout.length; i++) {
      if (i === root.selected || !root.alive(i) || !root.layout[i]) continue
      var r = root.layout[i]
      var ex = r.x + r.width / 2 - cx, ey = r.y + r.height / 2 - cy
      var along = dx !== 0 ? ex * dx : ey * dy
      if (along <= 1) continue
      var across = dx !== 0 ? Math.abs(ey) : Math.abs(ex)
      var score = along + across * 2
      if (score < bestScore) { bestScore = score; bestIndex = i }
    }
    if (bestIndex >= 0) root.selected = bestIndex
  }
  function cycleSelection() {
    if (root.aliveCount() === 0) return
    var i = root.selected
    do { i = (i + 1) % root.windows.length } while (!root.alive(i))
    root.selected = i
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: root.leave("")
    Keys.onReturnPressed: if (root.alive(root.selected)) root.leave(root.windows[root.selected].address)
    Keys.onEnterPressed: if (root.alive(root.selected)) root.leave(root.windows[root.selected].address)
    Keys.onDeletePressed: root.dismiss(root.selected)
    Keys.onLeftPressed: root.moveSelection(-1, 0)
    Keys.onRightPressed: root.moveSelection(1, 0)
    Keys.onUpPressed: root.moveSelection(0, -1)
    Keys.onDownPressed: root.moveSelection(0, 1)
    Keys.onTabPressed: root.cycleSelection()
  }

  // The desktop without its windows: the wallpaper, dimmed as the windows
  // spread out, with holes where the bar and the dock show through. It is
  // there from the first frame, under copies that cover the windows exactly.
  Item {
    id: backdrop
    anchors.fill: parent
    visible: false
    layer.enabled: true
    BackgroundMedia {
      id: wallpaper
      anchors.fill: parent
      path: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
      cached: true
      constrainDecode: true
      decodeSize: Qt.size(Math.round(root.width * (root.screen ? root.screen.devicePixelRatio : 1)), Math.round(root.height * (root.screen ? root.screen.devicePixelRatio : 1)))
    }
  }
  Item {
    id: holeMask
    anchors.fill: parent
    visible: false
    layer.enabled: true
    Repeater {
      id: holeItems
      model: root.holes
      delegate: Rectangle {
        required property var modelData
        x: modelData.x; y: modelData.y; width: modelData.width; height: modelData.height
        color: "white"
      }
    }
  }
  MultiEffect {
    anchors.fill: parent
    source: backdrop
    maskEnabled: root.holes.length > 0
    maskSource: holeMask
    maskInverted: true
    visible: root.shown
  }
  // The dimming, over everything but the bar: the dock darkens with the
  // desktop like the rest, only the bar stays as it is.
  Rectangle {
    x: root.reserved[0]
    y: root.reserved[1]
    width: root.width - root.reserved[0] - root.reserved[2]
    height: root.height - root.reserved[1] - root.reserved[3]
    color: Qt.rgba(0, 0, 0, 0.42 * root.progress)
    visible: root.shown
  }
  // A click on the empty space leaves.
  MouseArea { anchors.fill: parent; enabled: root.shown; onClicked: root.leave("") }

  // One particle system for every burst.
  // Runs only while Exposé is up: a running particle system ticks every
  // frame, even with no particles to draw.
  ParticleSystem { id: sparks; anchors.fill: parent; running: root.open || root.closing }
  ImageParticle {
    system: sparks
    anchors.fill: parent
    // Above every window copy.
    z: 3000
    source: Qt.resolvedUrl("images/particle.png")
    color: Qt.lighter(Commons.Color.accent, 1.35)
    colorVariation: 0.25
    alpha: 0.95
    alphaVariation: 0.2
    entryEffect: ImageParticle.Scale
  }
  Gravity { system: sparks; anchors.fill: parent; angle: 90; magnitude: 140 }

  Repeater {
    id: tiles
    model: root.windows.length
    delegate: Item {
      id: tile
      required property int index
      readonly property var win: root.windows[index] || null
      readonly property rect home: win ? win.home : Qt.rect(0, 0, 0, 0)
      readonly property real bar: win ? win.bar : 0
      readonly property bool closed: !!root.gone[index]
      readonly property bool chosen: !!win && root.chosenAddress === win.address
      readonly property bool hot: (mouse.containsMouse || closeMouse.containsMouse || root.selected === index) && !closed && root.shown
      readonly property bool ready: preview.hasContent
      readonly property real p: root.progress
      // How much the window is scaled right now: the titlebar follows it.
      readonly property real shrink: home.height > 0 ? height / home.height : 1

      // The cell, eased whenever the grid changes after a window closed. A
      // closed window bursts where it was.
      readonly property rect target: closed ? (root.frozen[index] || home) : (root.layout[index] || home)
      property real cx: target.x
      property real cy: target.y
      property real cw: target.width
      property real ch: target.height
      Behavior on cx { enabled: root.progress >= 1 && !root.closing; NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
      Behavior on cy { enabled: root.progress >= 1 && !root.closing; NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
      Behavior on cw { enabled: root.progress >= 1 && !root.closing; NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
      Behavior on ch { enabled: root.progress >= 1 && !root.closing; NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }

      x: home.x + (cx - home.x) * p
      y: home.y + (cy - home.y) * p
      width: home.width + (cw - home.width) * p
      height: home.height + (ch - home.height) * p
      // Stacked as the windows are (most recently focused on top) while they
      // are where the windows are; the picked one on top on the way back.
      // Stacked as the windows are while they are where the windows are;
      // the one under the pointer, and the picked one on the way back, on top.
      z: chosen ? 2000 : (hot && root.progress >= 1 ? 1500 : 100 + (win ? win.layer : 0))
      visible: root.shown && (!closed || pop < 1)

      // Popping: a little bigger, then gone, while the sparks fly.
      property real pop: 0
      opacity: closed ? 1 - pop : 1
      scale: (closed ? 1 + 0.08 * pop : 1) * (hot && !root.closing ? 1.02 : 1)
      Behavior on scale { enabled: !tile.closed; NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }

      onClosedChanged: if (closed) { burst.burst(Math.round(Math.min(420, 120 + width * height / 900))); popAnim.restart() }
      NumberAnimation { id: popAnim; target: tile; property: "pop"; from: 0; to: 1; duration: Style.duration(220); easing.type: Easing.OutQuad }

      Emitter {
        id: burst
        system: sparks
        anchors.fill: parent
        enabled: false
        emitRate: 0
        lifeSpan: 760
        lifeSpanVariation: 260
        size: 9
        sizeVariation: 6
        endSize: 2
        shape: RectangleShape {}
        velocity: AngleDirection { angleVariation: 180; magnitude: 230; magnitudeVariation: 170 }
        acceleration: PointDirection { xVariation: 40; yVariation: 40 }
      }

      // The titlebar, as hyprbars draws it with the current theme.
      Rectangle {
        id: titlebarItem
        width: parent.width
        height: tile.bar * tile.shrink
        visible: tile.bar > 0
        color: root.titlebar.color
        Text {
          // Clear of hyprbars' buttons and of the X on the corner.
          readonly property real buttonsRoom: Math.max(closeButton.size / 2 + Style.space(8), (3 * 20 + 2 * 8 + 16) * tile.shrink)
          x: 10 * tile.shrink
          width: Math.max(0, parent.width - x - buttonsRoom)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: tile.win ? tile.win.title : ""
          elide: Text.ElideRight
          color: root.titlebar.text
          font.family: "monospace"
          font.pixelSize: Math.max(1, root.titlebar.textSize * tile.shrink)
          visible: font.pixelSize >= 6
        }
        // hyprbars' own buttons (− □ ×), where the window has them, so the
        // copy matches the window; they give way to Exposé's X.
        Row {
          anchors.right: parent.right
          anchors.rightMargin: 10 * tile.shrink
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8 * tile.shrink
          opacity: 1 - Math.min(1, root.progress * 2.5)
          visible: opacity > 0
          Repeater {
            model: ["−", "□", "×"]
            delegate: Text {
              required property string modelData
              width: 20 * tile.shrink
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: modelData
              color: root.titlebar.text
              font.family: "monospace"
              font.pixelSize: Math.max(1, root.titlebar.textSize * tile.shrink)
            }
          }
        }
      }

      ScreencopyView {
        id: preview
        x: 0
        y: titlebarItem.visible ? titlebarItem.height : 0
        width: parent.width
        height: parent.height - y
        captureSource: (root.open || root.prepared) && tile.win && !tile.closed ? tile.win.toplevel : null
        live: true
      }

      // The highlight around the window under the pointer or picked with the keys.
      Rectangle {
        anchors.fill: parent
        anchors.margins: -4
        radius: 6
        color: "transparent"
        border.width: 3
        border.color: Commons.Color.accent
        opacity: tile.hot && !root.closing ? root.progress : 0
        antialiasing: true
        Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.shown && !root.closing && !tile.closed
        onClicked: root.leave(tile.win ? tile.win.address : "")
      }

      // App and title, below the window.
      Rectangle {
        id: caption
        readonly property real maxWidth: Math.max(tile.width, Style.space(150))
        readonly property real padding: Style.space(11)
        readonly property real iconWidth: captionIcon.visible ? captionIcon.width + Style.space(6) : 0
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height + Style.space(10)
        width: Math.min(maxWidth, captionText.implicitWidth + iconWidth + padding * 2)
        height: Style.space(26)
        radius: height / 2
        color: tile.hot ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.14)
        border.width: 1
        border.color: tile.hot ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.18)
        opacity: root.progress * root.progress
        Behavior on color { ColorAnimation { duration: Style.duration(120) } }

        Image {
          id: captionIcon
          x: caption.padding
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(16); height: width
          source: tile.win ? tile.win.icon : ""
          sourceSize: Qt.size(width * 2, height * 2)
          smooth: true
          visible: status === Image.Ready
        }
        Text {
          id: captionText
          x: caption.padding + caption.iconWidth
          anchors.verticalCenter: parent.verticalCenter
          width: caption.width - x - caption.padding
          textFormat: Text.PlainText
          text: tile.win ? tile.win.title : ""
          elide: Text.ElideRight
          color: tile.hot ? Commons.Color.background : "white"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: Font.Medium
        }
      }

      // The X, centred on the window's top right corner: closes this window.
      Rectangle {
        id: closeButton
        readonly property real size: Style.space(26)
        x: parent.width - size / 2
        y: -size / 2
        width: size; height: size
        radius: size / 2
        // Dark with a light ring, so it reads over the titlebar and over the
        // wallpaper alike.
        color: closeMouse.containsMouse ? "#e5484d" : Qt.rgba(0.1, 0.1, 0.12, 0.92)
        border.width: 1.5
        border.color: closeMouse.containsMouse ? "#ff6369" : Qt.rgba(1, 1, 1, 0.55)
        opacity: tile.closed ? 0 : root.progress * (tile.hot ? 1 : 0.8)
        scale: closeMouse.pressed ? 0.9 : (closeMouse.containsMouse ? 1.1 : 1)
        antialiasing: true
        Behavior on color { ColorAnimation { duration: Style.duration(110) } }
        Behavior on scale { NumberAnimation { duration: Style.duration(110); easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

        // Two rounded strokes, drawn rather than taken from a font.
        Repeater {
          model: 2
          delegate: Rectangle {
            required property int index
            anchors.centerIn: parent
            width: closeButton.size * 0.42; height: 2
            radius: 1
            rotation: index === 0 ? 45 : -45
            color: "white"
            antialiasing: true
          }
        }
        MouseArea {
          id: closeMouse
          anchors.fill: parent
          anchors.margins: -4
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          enabled: root.shown && !root.closing && !tile.closed
          onClicked: root.dismiss(tile.index)
        }
      }
    }
  }
}
