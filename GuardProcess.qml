import QtQuick
import Quickshell.Io

// A short Plugin Guard command run by the panel (status, models, a saved
// report, a setting). Start it with start(), not by setting running. It is
// stopped if it runs past `deadline`, and `finished` fires exactly once per
// run however the run ends: an exit, a stop at the deadline, or a command
// that never started. (Quickshell clears running for a command that fails to
// start without ever reporting it running, and without an exit.) So a
// command that hangs or fails to start can never leave the panel waiting.
// Plugin Guard bounds what these commands print; `limit` is the panel's own
// backstop, and longer output is dropped.
Process {
  id: proc

  property int deadline: 30000
  property int limit: 8 * 1024 * 1024
  property bool timedOut: false
  property bool reported: true
  property bool collected: false
  property bool exited: false
  property bool overflow: false
  property int exitCode: -1
  property string output: ""

  signal finished(bool ok, string text)

  function start() {
    if (running || !reported) return false
    timedOut = false
    reported = false
    collected = false
    exited = false
    overflow = false
    exitCode = -1
    output = ""
    watchdog.restart()
    running = true
    return true
  }

  // Normally the output closes, running clears, and then the exit arrives.
  function settled() {
    if (exited && collected) report()
  }

  function report() {
    if (reported) return
    reported = true
    watchdog.stop()
    settle.stop()
    finished(!timedOut && !overflow && exited && exitCode === 0, output)
  }

  stdout: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      proc.overflow = text.length > proc.limit
      proc.output = proc.overflow ? "" : text
      proc.collected = true
      proc.settled()
    }
  }

  onExited: function(code) {
    exitCode = code
    exited = true
    settled()
  }

  // Covers a command that never started, and output that never closes
  // because something the command left behind still holds it.
  onRunningChanged: if (!running && !reported) settle.restart()

  property Timer watchdog: Timer {
    interval: proc.deadline
    onTriggered: {
      proc.timedOut = true
      proc.running = false
      proc.settle.restart()
    }
  }

  property Timer settle: Timer {
    interval: 500
    onTriggered: proc.report()
  }
}
