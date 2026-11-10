import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io
import qs.Ui as Ui

// A text field that never lets Qt read the clipboard itself. Qt's paste reads
// the whole clipboard offer before the field sees it, with no size or time
// limit, inside the shell; another program owning the clipboard could stream
// text into it without end. Here every paste gesture (Ctrl+V and its
// variants, Shift+Insert, the Paste key, the context menu, and middle-click
// for the primary selection) runs `plugin-guard paste` in a child process
// instead, which reads at most 4 KiB within 2 seconds, and only that text is
// inserted. Text dragged onto the field is discarded unread.
//
// A reply is inserted only if nothing happened since the paste was asked
// for: each request gets a number, and typing, moving the cursor, changing
// the selection, or leaving the field moves the number on and stops the
// helper, so a late reply is dropped rather than compared against the text.
Ui.TextField {
  id: root

  // Path to bin/plugin-guard.
  property string guardScript: ""
  property string pasteError: ""
  property int pasteRequest: 0
  property int pendingRequest: -1
  property int pasteStart: 0
  property int pasteEnd: 0
  property bool applyingPaste: false
  property bool replied: false
  readonly property bool pasteBusy: pasteProc.running

  maximumLength: 2048

  function invalidatePaste() {
    if (applyingPaste) return
    pasteRequest++
    pendingRequest = -1
    if (pasteProc.running) pasteProc.running = false
  }

  function requestPaste(primary) {
    if (!enabled || readOnly || pasteBusy || guardScript === "") return
    forceActiveFocus()
    pasteError = ""
    pasteStart = Math.min(selectionStart, selectionEnd)
    pasteEnd = Math.max(selectionStart, selectionEnd)
    pasteRequest++
    pendingRequest = pasteRequest
    replied = false
    pasteProc.command = ["python3", "-I", guardScript, "paste", primary ? "primary" : "clipboard"]
    pasteProc.running = true
    pasteWatchdog.restart()
  }

  function failPaste(message) {
    pendingRequest = -1
    pasteError = message
    errorTimer.restart()
  }

  function receivePaste(reply) {
    replied = true
    var request = pendingRequest
    pendingRequest = -1
    if (request < 0 || request !== pasteRequest || !activeFocus || !enabled || readOnly) return
    var value = null
    try {
      value = JSON.parse(String(reply || "").slice(0, 65536))
    } catch (e) {}
    if (!value || value.ok !== true || typeof value.text !== "string") {
      failPaste(value && typeof value.error === "string" ? value.error.slice(0, 300) : "Could not paste the clipboard.")
      return
    }
    var room = Math.max(0, maximumLength - (length - (pasteEnd - pasteStart)))
    var incoming = value.text.slice(0, room)
    applyingPaste = true
    remove(pasteStart, pasteEnd)
    insert(pasteStart, incoming)
    cursorPosition = pasteStart + incoming.length
    applyingPaste = false
    pasteRequest++
  }

  onTextEdited: invalidatePaste()
  onCursorPositionChanged: invalidatePaste()
  onSelectionStartChanged: invalidatePaste()
  onSelectionEndChanged: invalidatePaste()
  onActiveFocusChanged: if (!activeFocus) invalidatePaste()
  onEnabledChanged: invalidatePaste()

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    if (event.matches(StandardKey.Paste) || event.key === Qt.Key_Paste
        || (ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) {
      event.accepted = true
      root.requestPaste(false)
    }
  }

  // Takes the whole middle-button gesture before the field can paste the
  // primary selection, and the right button for the menu below.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.IBeamCursor
    onPressed: function(mouse) {
      root.forceActiveFocus()
      if (mouse.button === Qt.MiddleButton) {
        root.cursorPosition = root.positionAt(mouse.x, mouse.y)
        root.requestPaste(true)
      } else {
        menu.popup()
      }
    }
  }

  // Accepted so nothing else reads a drop, and never read here.
  DropArea {
    anchors.fill: parent
    onEntered: function(drag) { drag.accepted = true }
    onDropped: function(drop) { drop.accepted = true }
  }

  // Replaces the style's menu, whose Paste would use Qt's own reader.
  Controls.ContextMenu.menu: menu
  Controls.Menu {
    id: menu
    Controls.MenuItem { text: qsTr("Cut"); enabled: root.selectedText.length > 0 && !root.readOnly; onTriggered: root.cut() }
    Controls.MenuItem { text: qsTr("Copy"); enabled: root.selectedText.length > 0; onTriggered: root.copy() }
    Controls.MenuItem { text: qsTr("Paste"); enabled: !root.readOnly && !root.pasteBusy; onTriggered: root.requestPaste(false) }
    Controls.MenuItem { text: qsTr("Select all"); onTriggered: root.selectAll() }
  }

  Process {
    id: pasteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.receivePaste(text)
    }
    // Also covers a helper that never started, which clears running without
    // an exit.
    onRunningChanged: {
      if (running) return
      pasteWatchdog.stop()
      settle.restart()
    }
  }

  // A reply is read when the helper's output closes, which can land just
  // after running clears; give it that moment before calling it failed.
  Timer {
    id: settle
    interval: 300
    onTriggered: if (root.pendingRequest >= 0 && !root.replied) root.failPaste("Could not read the clipboard.")
  }

  // The helper stops itself after 2 seconds; this is the backstop.
  Timer {
    id: pasteWatchdog
    interval: 4000
    onTriggered: {
      root.invalidatePaste()
      root.failPaste("The clipboard did not answer in time.")
    }
  }

  Timer {
    id: errorTimer
    interval: 6000
    onTriggered: root.pasteError = ""
  }
}
