import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// A brief glow around the window that Alt+Tab just focused: a soft frame in
// the theme's accent color that settles onto the window's edge and fades
// away. One overlay per screen, click-through, mapped only while it plays.
PanelWindow {
  id: root

  // The window's outer rectangle (titlebar included), in this screen's
  // coordinates, and its corner radius.
  property rect target: Qt.rect(0, 0, 0, 0)
  property real radius: 0
  property real progress: 0
  readonly property color tint: Commons.Color.accent

  visible: glow.running
  color: "transparent"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "nov-dock-focus-glow"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region {}

  function play(rect, cornerRadius) {
    glow.stop()
    root.target = rect
    root.radius = Math.max(0, cornerRadius)
    root.progress = 0
    glow.start()
  }

  // In quickly, a moment at full strength, then a long soft fade.
  SequentialAnimation {
    id: glow
    NumberAnimation { target: root; property: "progress"; from: 0; to: 1; duration: Style.reduceMotion ? 0 : Style.duration(140); easing.type: Easing.OutCubic }
    PauseAnimation { duration: Style.reduceMotion ? 300 : Style.duration(160) }
    NumberAnimation { target: root; property: "progress"; to: 0; duration: Style.reduceMotion ? 0 : Style.duration(520); easing.type: Easing.InOutSine }
  }

  // The frame starts a few pixels outside the window and settles onto it.
  readonly property real spread: 10 * (1 - root.progress)

  Item {
    id: frame
    x: root.target.x - root.spread
    y: root.target.y - root.spread
    width: root.target.width + root.spread * 2
    height: root.target.height + root.spread * 2
    opacity: root.progress

    // The soft halo, blurred out from a ring around the window.
    Rectangle {
      id: halo
      anchors.fill: parent
      anchors.margins: -4
      radius: root.radius + 4
      color: "transparent"
      border.width: 6
      border.color: root.tint
      visible: false
      layer.enabled: true
    }
    MultiEffect {
      source: halo
      anchors.fill: halo
      blurEnabled: true
      blur: 1.0
      blurMax: 24
      brightness: 0.1
      opacity: 0.85
    }

    // The crisp line on the window's edge.
    Rectangle {
      anchors.fill: parent
      radius: root.radius
      color: "transparent"
      border.width: 2
      border.color: Qt.lighter(root.tint, 1.15)
      antialiasing: true
    }
  }
}
