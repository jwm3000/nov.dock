import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// The macOS "genie" for minimizing into the dock and coming back out of it.
// A snapshot of the window is cut into thin strips across the direction of
// travel. The strips nearest the dock narrow toward the dock slot first and
// lead the way down; the far ones follow, which bends the window into a
// funnel that pours into the slot. Restoring plays the same thing backwards.
//
// One overlay per screen: a click-through surface above everything, mapped
// only while an animation runs.
PanelWindow {
  id: root

  // "bottom", "top", "left" or "right": where the dock sits.
  property string edge: "bottom"
  // Window and slot rectangles in this screen's coordinates.
  property rect from: Qt.rect(0, 0, 0, 0)
  property var targetFn: null
  property var source: null
  // 0 = window, 1 = in the slot.
  property real progress: 0
  property bool running: false
  property var finished: null
  readonly property int strips: 40

  visible: running
  color: "transparent"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "nov-dock-genie"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region {}

  // Minimize: window -> slot. Restore: slot -> window. done() runs when the
  // animation is over (restore uses it to bring the real window back).
  function play(toplevel, windowRect, slotFn, reverse, done) {
    anim.stop()
    root.source = toplevel
    root.from = windowRect
    root.targetFn = slotFn
    root.finished = done || null
    root.progress = reverse ? 1 : 0
    anim.from = reverse ? 1 : 0
    anim.to = reverse ? 0 : 1
    root.running = true
    // The snapshot needs a frame to arrive; without one the window simply
    // goes (or comes) without the effect rather than waiting.
    startGuard.restart()
    if (shot.hasContent) begin()
  }

  function begin() {
    if (!root.running || anim.running) return
    startGuard.stop()
    anim.start()
  }

  function end() {
    var done = root.finished
    root.finished = null
    if (done) done()
    // One more frame of the last strip state while the real window maps.
    hideDelay.restart()
  }

  Timer { id: startGuard; interval: 250; onTriggered: { anim.stop(); root.end() } }
  Timer { id: hideDelay; interval: 60; onTriggered: { if (!anim.running) { root.running = false; root.source = null } } }

  NumberAnimation {
    id: anim
    target: root; property: "progress"
    duration: Style.reduceMotion ? 0 : Style.duration(520)
    easing.type: Easing.InOutSine
    onFinished: root.end()
  }

  // The snapshot itself is never drawn, only sampled by the strips.
  ScreencopyView {
    id: shot
    x: 0; y: 0
    width: Math.max(1, root.from.width)
    height: Math.max(1, root.from.height)
    captureSource: root.running ? root.source : null
    live: false
    onHasContentChanged: if (hasContent) root.begin()
  }

  readonly property rect target: {
    var p = root.progress
    var t = root.targetFn ? root.targetFn() : null
    return t ? t : Qt.rect(root.from.x + root.from.width / 2, root.from.y + root.from.height, 1, 1)
  }

  // Everything below works in a frame where the dock is underneath: the
  // other edges are mirrored and/or transposed into it and back out again.
  function toCanon(r) {
    if (root.edge === "top") return { x: r.x, y: -(r.y + r.height), w: r.width, h: r.height }
    if (root.edge === "right") return { x: r.y, y: r.x, w: r.height, h: r.width }
    if (root.edge === "left") return { x: r.y, y: -(r.x + r.width), w: r.height, h: r.width }
    return { x: r.x, y: r.y, w: r.width, h: r.height }
  }
  function fromCanon(c) {
    if (root.edge === "top") return { x: c.x, y: -(c.y + c.h), w: c.w, h: c.h }
    if (root.edge === "right") return { x: c.y, y: c.x, w: c.h, h: c.w }
    if (root.edge === "left") return { x: -c.y - c.h, y: c.x, w: c.h, h: c.w }
    return c
  }
  // Which part of the snapshot a strip shows, for canonical span v0..v1.
  function sourcePart(v0, v1) {
    var w = shot.width, h = shot.height
    if (root.edge === "top") return Qt.rect(0, (1 - v1) * h, w, (v1 - v0) * h)
    if (root.edge === "right") return Qt.rect(v0 * w, 0, (v1 - v0) * w, h)
    if (root.edge === "left") return Qt.rect((1 - v1) * w, 0, (v1 - v0) * w, h)
    return Qt.rect(0, v0 * h, w, (v1 - v0) * h)
  }

  function clamp01(t) { return Math.max(0, Math.min(1, t)) }
  function smooth(t) { t = clamp01(t); return t * t * (3 - 2 * t) }
  function lerp(a, b, t) { return a + (b - a) * t }

  readonly property var canonFrom: toCanon(root.from)
  readonly property var canonTo: toCanon(root.target)

  // v runs from the far edge (0) to the edge nearest the dock (1).
  function travel(v) {
    var p = root.progress
    return smooth((p - 0.15 - 0.3 * (1 - v)) / 0.55)
  }
  function squeeze(v) {
    var p = root.progress
    return smooth((p - 0.3 * (1 - v)) / 0.5)
  }
  function edgeAt(v) {
    var s = root.canonFrom, t = root.canonTo
    return lerp(s.y + v * s.h, t.y + v * t.h, travel(v))
  }

  Repeater {
    model: root.running ? root.strips : 0
    delegate: ShaderEffectSource {
      required property int index
      readonly property real v0: index / root.strips
      readonly property real v1: (index + 1) / root.strips
      readonly property var box: {
        var p = root.progress
        var s = root.canonFrom, t = root.canonTo
        var mid = (v0 + v1) / 2
        var f = root.squeeze(mid)
        var w = root.lerp(s.w, t.w, f)
        var cx = root.lerp(s.x + s.w / 2, t.x + t.w / 2, f)
        var y0 = root.edgeAt(v0), y1 = root.edgeAt(v1)
        // A hair of overlap keeps seams from showing between strips.
        return root.fromCanon({ x: cx - w / 2, y: y0, w: w, h: Math.max(0.5, y1 - y0 + 0.6) })
      }
      x: box.x; y: box.y; width: Math.max(0.5, box.w); height: Math.max(0.5, box.h)
      sourceItem: shot
      sourceRect: root.sourcePart(v0, v1)
      hideSource: true
      smooth: true
      // Melts into the slot over the last stretch.
      opacity: 1 - root.smooth((root.progress - 0.88) / 0.12)
    }
  }
}
