import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "nov.dock"
  property var current: ({})
  property var selected: ({})
  property bool opening: false
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("desktop.py").toString().replace(/^file:\/\//, ""))
  readonly property var monitor: root.QsWindow.window ? Hyprland.monitorFor(root.QsWindow.window.screen) : Hyprland.focusedMonitor
  readonly property int workspaceId: monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
  visible: current.floating === true
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0
  readonly property bool opened: panel.open

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  function refresh() { if (!reader.running && !panel.open) reader.running = true }
  function open() { if (!root.visible) return; opening = true; refresh() }
  function close() { panel.open = false }
  // Flips the border switch at once and runs the change behind it.
  function toggleSetting(action, key) {
    if (actionProc.running || (action !== "border" && action !== "focus-glow")) return
    actionProc.command = ["python3", root.helper, action]
    var next = Object.assign({}, root.selected)
    next[key] = !next[key]
    root.selected = next
    actionProc.running = true
  }
  onWorkspaceIdChanged: debounce.restart()
  Component.onCompleted: refresh()
  Timer { id: debounce; interval: 80; onTriggered: root.refresh() }
  // Mode changes have no dedicated compositor event; also catches saved default changes.
  Timer { interval: 1500; repeat: true; running: !panel.open; onTriggered: root.refresh() }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["activewindowv2", "workspacev2", "configreloaded", "closewindow"].indexOf(String(event.name)) >= 0) debounce.restart()
    }
  }
  Process {
    id: reader
    command: ["python3", root.helper, "state", String(root.workspaceId)]
    stdout: StdioCollector { onStreamFinished: {
      try { root.current = JSON.parse(text) } catch (e) { root.current = ({}) }
    } }
    onExited: function(code) {
      if (root.opening) {
        root.opening = false
        root.selected = root.current
        if (code === 0 && root.visible) panel.open = true
      }
    }
  }
  Process {
    id: actionProc
    onExited: function(code) {
      if (code !== 0) errorNotice.running = true
      debounce.restart()
    }
  }
  Process { id: errorNotice; command: ["notify-send", strings.t("name"), strings.t("actionError")] }

  WidgetButton {
    id: button
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: Style.bar.iconSlot
    tooltipText: strings.t("windowMenu")
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton || mouseButton === Qt.RightButton) {
        if (panel.open) root.close(); else root.open()
      }
    }
    // A small window: outline with a filled title bar and two tiny dots.
    Item {
      id: glyph
      anchors.centerIn: parent
      readonly property real line: Math.max(1, Math.round(Style.space(1.2)))
      width: Math.round(Style.space(11)); height: Math.round(Style.space(9))
      Rectangle {
        anchors.fill: parent
        radius: Style.space(1.8)
        color: "transparent"
        border.width: glyph.line
        border.color: button.foreground
      }
      Rectangle {
        x: 0; y: 0; width: parent.width; height: Math.round(Style.space(3))
        radius: Style.space(1.8)
        color: button.foreground
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: parent.radius; color: parent.color }
      }
    }
  }
  KeyboardPanel {
    id: panel
    bar: root.bar
    anchorItem: button
    owner: root
    contentWidth: Style.space(290)
    // Includes the card padding and border, as the shell panels do.
    contentHeight: panel.fittedContentHeight(actions.implicitHeight)
    Column {
      id: actions
      width: parent.width
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.selected.canControl ? root.selected.title : strings.t("noWindow")
        color: Commons.Color.popups.text
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        height: Style.spacing.popupRowHeight
        verticalAlignment: Text.AlignVCenter
      }
      // Borders are one setting for all floating windows; the switch flips at
      // once and the panel stays open.
      Toggle {
        width: parent.width
        label: strings.t("border")
        description: strings.t("borderAll")
        checked: !root.selected.borderless
        onClicked: root.toggleSetting("border", "borderless")
      }
      // The glow around the window Alt+Tab lands on; on by default.
      Toggle {
        width: parent.width
        label: strings.t("focusGlow")
        description: strings.t("focusGlowHint")
        checked: root.selected.focusGlow !== false
        onClicked: root.toggleSetting("focus-glow", "focusGlow")
      }
    }
  }
}
