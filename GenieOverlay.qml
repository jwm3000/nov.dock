import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// The macOS "genie" for minimizing into the dock and coming back out of it.
// A snapshot of the window is drawn on a fine mesh that a vertex shader
// bends: the side nearest the dock narrows toward the slot first and leads
// the way, the rest follows, and the window pours into the slot along smooth
// curves (shaders/genie.vert). Restoring plays the same thing backwards.
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
    // One more frame of the last state while the real window maps.
    hideDelay.restart()
  }

  Timer { id: startGuard; interval: 250; onTriggered: { anim.stop(); root.end() } }
  Timer { id: hideDelay; interval: 60; onTriggered: { if (!anim.running) { root.running = false; root.source = null } } }

  // Linear in time: the shader eases every part of the window on its own
  // staggered curve, so the motion as a whole starts and lands softly.
  NumberAnimation {
    id: anim
    target: root; property: "progress"
    duration: Style.reduceMotion ? 0 : Style.duration(600)
    easing.type: Easing.Linear
    onFinished: root.end()
  }

  // The snapshot itself is never drawn, only sampled by the mesh.
  ScreencopyView {
    id: shot
    x: 0; y: 0
    width: Math.max(1, root.from.width)
    height: Math.max(1, root.from.height)
    captureSource: root.running ? root.source : null
    live: false
    onHasContentChanged: if (hasContent) root.begin()
  }

  // Mipmapped, so the window stays clean as it shrinks toward the slot.
  ShaderEffectSource {
    id: texture
    sourceItem: shot
    hideSource: true
    live: true
    smooth: true
    mipmap: true
    visible: false
  }

  readonly property rect target: {
    var t = root.targetFn ? root.targetFn() : null
    return t ? t : Qt.rect(root.from.x + root.from.width / 2, root.from.y + root.from.height, 1, 1)
  }

  // The shader works in a frame where the dock lies below the window; the
  // other edges are mirrored and/or transposed into it (and back out again
  // in the shader).
  function canon(r) {
    if (root.edge === "top") return Qt.vector4d(r.x, -(r.y + r.height), r.width, r.height)
    if (root.edge === "right") return Qt.vector4d(r.y, r.x, r.height, r.width)
    if (root.edge === "left") return Qt.vector4d(r.y, -(r.x + r.width), r.height, r.width)
    return Qt.vector4d(r.x, r.y, r.width, r.height)
  }

  ShaderEffect {
    id: genie
    anchors.fill: parent
    visible: root.running && status !== ShaderEffect.Error
    // Dense along the direction of travel, where the curves are.
    mesh: GridMesh { resolution: root.edge === "left" || root.edge === "right" ? Qt.size(128, 2) : Qt.size(2, 128) }
    blending: true
    property variant source: texture
    property real progress: root.progress
    property real edge: root.edge === "top" ? 1 : root.edge === "left" ? 2 : root.edge === "right" ? 3 : 0
    property vector4d fromRect: root.canon(root.from)
    property vector4d toRect: root.canon(root.target)
    // Melts into the slot over the last stretch.
    opacity: 1 - Math.max(0, Math.min(1, (root.progress - 0.9) / 0.1))
    vertexShader: Qt.resolvedUrl("shaders/genie.vert.qsb")
    fragmentShader: Qt.resolvedUrl("shaders/genie.frag.qsb")
  }

  // Should the shaders ever fail to load: the snapshot simply shrinks into
  // the slot, which still shows where the window went.
  ShaderEffectSource {
    visible: root.running && genie.status === ShaderEffect.Error
    sourceItem: shot
    smooth: true
    readonly property real eased: root.progress * root.progress * (3 - 2 * root.progress)
    x: root.from.x + (root.target.x - root.from.x) * eased
    y: root.from.y + (root.target.y - root.from.y) * eased
    width: root.from.width + (root.target.width - root.from.width) * eased
    height: root.from.height + (root.target.height - root.from.height) * eased
    opacity: 1 - eased * 0.6
  }
}
