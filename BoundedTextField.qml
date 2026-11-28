import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// A single-line text field that never lets Qt read the clipboard on its own.
//
// Qt's TextInput (under every TextField) reads the whole clipboard offer
// whenever the clipboard changes while it is writable, to decide whether
// Paste is available, with no size or time limit, inside the shell. TextEdit
// makes that decision from the offered formats alone (QQuickTextControl::
// canPaste -> QMimeData::hasText -> the offer's type list), so this field is
// built on TextEdit and styled like the host TextField. Every paste gesture
// (Ctrl+V and its variants, Shift+Insert, the Paste key, the context menu,
// and middle-click for the primary selection) runs `plugin-guard paste` in a
// child process instead, which reads at most 4 KiB within 2 seconds, and only
// that text is inserted. Text dragged onto the field is discarded unread.
//
// A reply is inserted only if nothing happened since the paste was asked
// for: each request gets a number, and typing, moving the cursor, changing
// the selection, or leaving the field moves the number on and stops the
// helper, so a late reply is dropped rather than compared against the text.
FocusScope {
  id: root

  // False while the popup that holds the field is closed.
  property bool live: true
  readonly property bool usable: live && visible && enabled && !readOnly

  // Path to bin/plugin-guard.
  property string guardScript: ""
  property bool readOnly: false
  property string pasteError: ""
  property alias text: edit.text
  property alias font: edit.font
  property alias inputMethodHints: edit.inputMethodHints
  property alias cursorPosition: edit.cursorPosition
  readonly property alias length: edit.length
  readonly property alias selectionStart: edit.selectionStart
  readonly property alias selectionEnd: edit.selectionEnd
  readonly property alias selectedText: edit.selectedText
  property string placeholderText: ""
  property int maximumLength: 2048
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  property int pasteRequest: 0
  property int pendingRequest: -1
  property int pasteStart: 0
  property int pasteEnd: 0
  property bool applyingPaste: false
  property string pasteOutput: ""
  property bool pasteStreamDone: false
  property int pasteExit: -1
  readonly property bool pasteBusy: pasteProc.running

  signal accepted()

  function selectAll() { edit.selectAll() }
  function select(start, end) { edit.select(start, end) }
  function copy() { edit.copy() }
  function cut() { if (!readOnly) edit.cut() }

  readonly property var borderSpec: Border.controlSpec(activeFocus ? "focus" : (hover.hovered ? "hover-cursor" : "normal"), foreground, accent)

  activeFocusOnTab: true
  implicitWidth: 200
  implicitHeight: Math.round(edit.implicitHeight + 2 * verticalPadding + Border.top(borderSpec) + Border.bottom(borderSpec))

  onUsableChanged: if (!usable && activeFocus) focus = false
  onActiveFocusChanged: {
    if (!activeFocus) invalidatePaste()
    else if (!usable) focus = false
  }
  onEnabledChanged: invalidatePaste()

  function invalidatePaste() {
    if (applyingPaste) return
    pasteRequest++
    pendingRequest = -1
    if (pasteProc.running) pasteProc.running = false
    pasteWatchdog.stop()
  }

  function requestPaste(primary) {
    if (!usable || pasteBusy || guardScript === "") return
    forceActiveFocus()
    if (!activeFocus) return
    pasteError = ""
    pasteStart = Math.min(edit.selectionStart, edit.selectionEnd)
    pasteEnd = Math.max(edit.selectionStart, edit.selectionEnd)
    pasteRequest++
    pendingRequest = pasteRequest
    pasteOutput = ""
    pasteStreamDone = false
    pasteExit = -1
    pasteProc.command = ["python3", "-I", guardScript, "paste", primary ? "primary" : "clipboard"]
    pasteProc.running = true
    pasteWatchdog.restart()
  }

  function failPaste(message) {
    pendingRequest = -1
    pasteWatchdog.stop()
    pasteError = message
    errorTimer.restart()
  }

  // The output and the exit can arrive in either order.
  function settlePaste() {
    if (!pasteStreamDone || pasteExit < 0) return
    receivePaste(pasteExit === 0 ? pasteOutput : "")
  }

  function receivePaste(reply) {
    var request = pendingRequest
    pendingRequest = -1
    pasteWatchdog.stop()
    if (request < 0 || request !== pasteRequest || !activeFocus || !usable) return
    var value = null
    try {
      value = JSON.parse(String(reply || "").slice(0, 65536))
    } catch (e) {}
    if (!value || value.ok !== true || typeof value.text !== "string") {
      failPaste(value && typeof value.error === "string" ? value.error.slice(0, 300) : "Could not paste the clipboard.")
      return
    }
    var room = Math.max(0, maximumLength - (edit.length - (pasteEnd - pasteStart)))
    var incoming = value.text.slice(0, room)
    applyingPaste = true
    edit.remove(pasteStart, pasteEnd)
    edit.insert(pasteStart, incoming)
    edit.cursorPosition = pasteStart + incoming.length
    applyingPaste = false
    pasteRequest++
  }

  // Keeps the field one line long and within maximumLength, whatever the
  // source (typing, an input method, or code setting text). Slices to
  // maximumLength first and normalizes line breaks in one pass so a large
  // multiline input-method commit cannot stall the shell.
  property bool fixingText: false
  readonly property var lineBreak: new RegExp("[\\r\\n\\u2028\\u2029]")
  readonly property var lineBreakAll: new RegExp("[\\r\\n\\u2028\\u2029]", "g")
  function fixText() {
    if (fixingText) return
    var raw = edit.text
    if (raw.length <= maximumLength && !lineBreak.test(raw)) return
    fixingText = true
    var pos = edit.cursorPosition
    var excess = raw.length - maximumLength
    if (excess > 0) {
      var cutStart = Math.max(0, pos - excess)
      raw = raw.slice(0, cutStart) + raw.slice(pos)
      pos = cutStart
      if (raw.length > maximumLength) raw = raw.slice(0, maximumLength)
    }
    var cleaned = raw.replace(lineBreakAll, " ")
    if (cleaned !== edit.text) {
      edit.text = cleaned
      edit.cursorPosition = Math.min(pos, cleaned.length)
    }
    fixingText = false
  }

  HoverHandler {
    id: hover
    cursorShape: Qt.IBeamCursor
  }

  Ui.BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root.activeFocus, hover.hovered, root.foreground, root.accent)
    borderSpec: root.borderSpec
    radius: Style.cornerRadius
  }

  // Clicking the padding focuses the field too.
  TapHandler {
    onTapped: if (root.usable) root.forceActiveFocus()
  }

  Item {
    id: viewport
    anchors.fill: parent
    anchors.leftMargin: root.horizontalPadding + Border.left(root.borderSpec)
    anchors.rightMargin: root.horizontalPadding + Border.right(root.borderSpec)
    anchors.topMargin: root.verticalPadding + Border.top(root.borderSpec)
    anchors.bottomMargin: root.verticalPadding + Border.bottom(root.borderSpec)
    clip: true

    // Scrolls a long line so the cursor stays in view.
    property real scroll: 0
    function follow() {
      var x = edit.cursorRectangle.x
      if (edit.contentWidth <= width) scroll = 0
      else if (x - scroll > width - 1) scroll = x - width + 1
      else if (x < scroll) scroll = x
    }
    onWidthChanged: follow()

    Text {
      anchors.fill: parent
      verticalAlignment: Text.AlignVCenter
      text: root.placeholderText
      textFormat: Text.PlainText
      elide: Text.ElideRight
      visible: edit.length === 0 && edit.preeditText === ""
      color: Qt.darker(root.foreground, 1.6)
      font: edit.font
    }

    TextEdit {
      id: edit
      focus: true
      readOnly: root.readOnly || !root.usable
      x: -viewport.scroll
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(viewport.width, implicitWidth)
      wrapMode: TextEdit.NoWrap
      textFormat: TextEdit.PlainText
      selectByMouse: true
      persistentSelection: false
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body

      onTextChanged: {
        root.fixText()
        if (!root.applyingPaste) root.invalidatePaste()
      }
      onCursorRectangleChanged: viewport.follow()
      onCursorPositionChanged: root.invalidatePaste()
      onSelectionStartChanged: root.invalidatePaste()
      onSelectionEndChanged: root.invalidatePaste()

      // The caller's own key handlers (on root) see each key first; then this
      // takes paste, Enter and Tab before the editor can.
      Keys.forwardTo: [root]
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        if (event.matches(StandardKey.Paste) || event.key === Qt.Key_Paste
            || (ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) {
          event.accepted = true
          root.requestPaste(false)
        } else if (event.text.length > 0 && !ctrl && event.text.charCodeAt(0) >= 32
                   && edit.length - Math.abs(edit.selectionEnd - edit.selectionStart) + event.text.length > root.maximumLength) {
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true
          root.accepted()
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          event.accepted = true
          var next = root.nextItemInFocusChain(event.key === Qt.Key_Tab && !shift)
          if (next && next !== root) next.forceActiveFocus(Qt.TabFocusReason)
        }
      }
    }
  }

  // Takes the middle button before the editor can paste the primary
  // selection through Qt, and the right button for the context menu.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.IBeamCursor
    onPressed: function(mouse) {
      if (!root.usable) return
      root.forceActiveFocus()
      if (mouse.button === Qt.MiddleButton) {
        var point = mapToItem(edit, mouse.x, mouse.y)
        edit.cursorPosition = edit.positionAt(point.x, point.y)
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

  Controls.Menu {
    id: menu
    Controls.MenuItem { text: qsTr("Cut"); enabled: root.selectedText.length > 0 && root.usable; onTriggered: root.cut() }
    Controls.MenuItem { text: qsTr("Copy"); enabled: root.selectedText.length > 0; onTriggered: root.copy() }
    Controls.MenuItem { text: qsTr("Paste"); enabled: root.usable && !root.pasteBusy; onTriggered: root.requestPaste(false) }
    Controls.MenuItem { text: qsTr("Select all"); onTriggered: root.selectAll() }
  }

  Process {
    id: pasteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pasteOutput = text
        root.pasteStreamDone = true
        root.settlePaste()
      }
    }
    onExited: function(code, status) {
      root.pasteExit = status === 0 ? Math.max(0, code) : 255
      root.settlePaste()
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
    onTriggered: if (root.pendingRequest >= 0 && !pasteProc.running) root.failPaste("Could not read the clipboard.")
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
