import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// A Downloads stack that fans out of its dock icon the way macOS does it: the
// newest download sits right above the stack, older ones climb away from it
// on a gentle arc, each with its name on a label beside the icon. The folder
// itself is the last step of the fan.
Item {
  id: root
  property var dock: null
  property string title: ""
  property string openFolderText: ""
  property string emptyText: ""
  // Where the stack icon's center sits, across this item; the fan grows out
  // of it. Toward the dock is down unless the dock is at the top.
  property real stackX: width / 2
  property bool fromTop: false
  signal dismissed()

  readonly property var files: dock ? dock.downloads : []
  readonly property int count: files.length
  // The folder rides along as the last step, so the fan always has one.
  readonly property int steps: count + 1
  readonly property int iconSize: Style.space(44)
  readonly property int rowHeight: Style.space(52)
  readonly property int labelMax: Style.space(190)
  // How far the arc leans at its far end, and how much it turns.
  // A gentle macOS-style curve: the lowest step sits right on the stack,
  // and the climb bends away from the labels the higher it goes.
  readonly property real lean: Style.space(44)
  readonly property real turn: 7
  height: steps * rowHeight + Style.space(8)

  // 0 while closed, 1 once the fan is out; each step trails the one nearer
  // the dock a little, so the fan unfolds rather than appears.
  property real progress: 0
  onVisibleChanged: {
    if (visible) {
      progress = 0
      unfold.restart()
    } else {
      unfold.stop()
    }
  }
  NumberAnimation {
    id: unfold
    target: root; property: "progress"; from: 0; to: 1
    duration: Style.reduceMotion ? 0 : Style.duration(340)
    easing.type: Easing.Linear
  }

  // Labels sit over arbitrary windows, so they get a solid backing.
  readonly property color pill: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g,
                                        Commons.Color.popups.background.b, 0.94)

  function easeOut(t) { var r = 1 - t; return 1 - r * r * r }
  function stepProgress(step) {
    var span = 0.55
    var start = root.steps > 1 ? step / (root.steps - 1) * (1 - span) : 0
    return root.easeOut(Math.max(0, Math.min(1, (root.progress - start) / span)))
  }
  // How far along the arc a step is: 0 at the stack, 1 at the far end.
  function along(step) { return root.steps > 1 ? step / (root.steps - 1) : 0 }

  // Clicks on the empty space between the steps close the fan.
  MouseArea { anchors.fill: parent; onClicked: root.dismissed() }

  Repeater {
    model: root.steps
    delegate: Item {
      id: step
      required property int index
      readonly property bool isFolder: index === root.count
      readonly property var file: isFolder ? null : root.files[index]
      readonly property real t: root.along(index)
      readonly property real p: root.stepProgress(index)
      readonly property bool hovered: mouse.containsMouse
      readonly property string iconName: isFolder ? "folder-download" : (file.icon || "text-x-generic")
      readonly property bool thumbnail: !isFolder && String(file.icon).indexOf("image-") === 0

      // Laid out from the stack outward; the arc bends away from the labels.
      readonly property real restY: root.fromTop ? Style.space(4) + index * root.rowHeight
                                               : root.height - (index + 1) * root.rowHeight
      readonly property real stackY: root.fromTop ? -root.rowHeight : root.height
      readonly property real dx: root.lean * t * t

      width: root.width
      height: root.rowHeight
      y: stackY + (restY - stackY) * p
      opacity: p
      z: root.steps - index

      transform: Rotation {
        origin.x: root.stackX
        origin.y: step.height / 2
        angle: (root.fromTop ? -1 : 1) * root.turn * step.t * step.t * step.p
      }

      // The icon, its label to the side, and a hover lift on both.
      Item {
        id: iconBox
        x: root.stackX - root.iconSize / 2 + step.dx * step.p
        anchors.verticalCenter: parent.verticalCenter
        width: root.iconSize
        height: root.iconSize
        scale: (0.55 + 0.45 * step.p) * (step.hovered ? 1.12 : 1)
        Behavior on scale { enabled: step.p >= 1; NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

        Image {
          id: thumb
          anchors.fill: parent
          visible: step.thumbnail && status === Image.Ready
          source: step.thumbnail ? step.file.uri : ""
          sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          mipmap: true
        }
        Image {
          anchors.fill: parent
          visible: !thumb.visible
          source: Quickshell.iconPath(step.iconName, true) || Quickshell.iconPath(step.isFolder ? "folder" : "text-x-generic", true)
          sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
          fillMode: Image.PreserveAspectFit
          // Theme icons load on the GUI thread: Quickshell's icon provider
          // crashes the shell when asked from a loader thread.
          smooth: true
          mipmap: true
        }
      }

      Rectangle {
        id: label
        readonly property real gapToIcon: Style.space(8)
        x: iconBox.x - gapToIcon - width
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(root.labelMax, name.implicitWidth + Style.space(20))
        height: name.implicitHeight + Style.space(8)
        radius: height / 2
        color: step.hovered ? Commons.Color.accent : root.pill
        border.width: Style.normalBorderWidth
        border.color: step.hovered ? Commons.Color.accent : Commons.Color.popups.border
        Behavior on color { ColorAnimation { duration: Style.duration(100) } }

        Text {
          id: name
          anchors.centerIn: parent
          width: Math.min(implicitWidth, root.labelMax - Style.space(20))
          textFormat: Text.PlainText
          text: step.isFolder ? root.openFolderText : step.file.name
          elide: Text.ElideMiddle
          color: step.hovered ? Commons.Color.background : Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: step.isFolder ? Font.DemiBold : Font.Medium
        }
      }

      MouseArea {
        id: mouse
        x: label.x
        width: iconBox.x + iconBox.width - label.x
        height: parent.height
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: step.p >= 1 && (!step.isFolder || (root.dock && root.dock.downloadsUri !== ""))
        onClicked: {
          // Straight to the default app, as a double-click in the file
          // browser does, rather than through the portal's "Open with".
          if (!step.isFolder && step.file.text && step.file.path)
            Quickshell.execDetached(["omarchy-launch-editor", step.file.path])
          else
            Quickshell.execDetached(["gio", "open", step.isFolder ? root.dock.downloadsUri : step.file.uri])
          root.dismissed()
        }
      }
    }
  }

  // Nothing finished yet (or still loading): say so right above the stack.
  Rectangle {
    visible: root.count === 0
    x: Math.max(0, Math.min(root.width - width, root.stackX - width / 2))
    y: root.fromTop ? root.rowHeight + Style.space(4) : root.height - root.rowHeight * 2
    width: emptyLabel.implicitWidth + Style.space(24)
    height: emptyLabel.implicitHeight + Style.space(10)
    radius: height / 2
    opacity: root.progress
    color: root.pill
    border.width: Style.normalBorderWidth
    border.color: Commons.Color.popups.border
    Text {
      id: emptyLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.emptyText
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
