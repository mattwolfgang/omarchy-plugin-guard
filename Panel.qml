import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Plugin Guard popup. Every action runs bin/plugin-guard with a fixed argv;
// the URL a user types is passed as one argument, never through a shell.
// Reports are untrusted text (they quote plugin code and model output), so
// every Text here is PlainText.
//
// Scans, installs, and updates run as detached systemd user units, not as
// child processes: the shell reloads every plugin widget whenever any plugin
// changes, and an install causes exactly that. The unit writes its progress
// and result to ~/.local/state/plugin-guard/job.json, which this panel reads,
// so a job survives the reload and the recreated panel picks it back up.
Panel {
  id: root
  moduleName: "io.github.mattwolfgang.plugin-guard"
  ipcTarget: "io.github.mattwolfgang.plugin-guard"
  manageIpc: false

  property var anchorItem: null
  // The bar identifies panels by the widget mounted in its slot
  // (BarWidget.qml), so hand that to KeyboardPanel as the owner.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string guardScript: String(Qt.resolvedUrl("bin/plugin-guard")).replace(/^file:\/\//, "")
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- Data.
  property var models: []
  property string currentModel: ""
  property var plugins: []
  property var report: null
  property string view: "home"
  property bool showInfo: false
  property bool confirmDangerous: false

  // ---- The one running job (scan, install, check, update, or apply) and the
  // background sweep, both read from the state files their units write.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/plugin-guard"
  property var jobState: ({})
  property var sweepState: ({})
  property string launchedUnit: ""
  property double launchedAt: 0
  property string handledJobId: ""
  property bool jobStateLoaded: false
  property string jobError: ""
  property string notice: ""
  // install.sh has not run and the reminder was not dismissed.
  property bool setupNeeded: false
  property double now: Date.now()

  // A unit's heartbeat lands every 5 s; one silent for 30 s has died.
  function alive(st) {
    if (!st || st.state !== "running") return false
    var t = Date.parse(st.updatedAt || "")
    return !isNaN(t) && now - t < 30000
  }
  readonly property bool launching: launchedUnit !== "" && jobState.unit !== launchedUnit && now - launchedAt < 15000
  readonly property bool busy: launching || alive(jobState)
  readonly property bool sweeping: alive(sweepState)
  readonly property string jobKind: launching ? "" : String(jobState.kind || "")
  readonly property string jobTarget: String(jobState.target || "")
  readonly property string jobMessage: launching ? "" : String(jobState.message || "")
  readonly property int elapsed: {
    var t = Date.parse(jobState.startedAt || "")
    return busy && !launching && !isNaN(t) ? Math.max(0, Math.round((now - t) / 1000)) : 0
  }

  readonly property var attention: plugins.filter(function(p) {
    return p.state !== "scanned" || p.verdict !== "safe"
  })
  readonly property bool anyDangerous: plugins.some(function(p) { return p.state === "scanned" && p.verdict === "dangerous" })

  readonly property string barIcon: (busy || sweeping) ? "󰒘" : (anyDangerous ? "󰻌" : (attention.length > 0 ? "󰒙" : "󰕥"))
  readonly property bool barAlert: !busy && !sweeping && anyDangerous
  readonly property string barTooltip: busy ? strings.t("tooltip.busy").arg(jobMessage || jobTarget)
    : sweeping ? strings.t("tooltip.busy").arg(String(sweepState.message || ""))
    : anyDangerous ? strings.t("tooltip.alert")
    : attention.length > 0 ? strings.tn("tooltip.attention", attention.length).arg(Commons.I18n.formatNumber(attention.length))
    : strings.t("tooltip.idle")

  function open() {
    root.controller.show()
    refreshStatus()
    refreshModels()
  }

  function close() {
    root.controller.hide()
    confirmDangerous = false
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function verdictColor(verdict) {
    return verdict === "dangerous" ? Color.urgent : (verdict === "caution" ? Color.accent : root.fg)
  }

  function verdictGlyph(verdict) {
    return verdict === "dangerous" ? "󰻌" : (verdict === "caution" ? "󰒙" : "󰕥")
  }

  function severityColor(severity) {
    if (severity === "critical" || severity === "high") return Color.urgent
    if (severity === "medium") return Color.accent
    return root.dim
  }

  function shortCommit(sha) { return sha ? String(sha).substring(0, 7) : "" }

  // ---- Commands.
  function unitCommand(unit, name, kind, target, args) {
    return ["systemd-run", "--user", "--collect", "--quiet", "--unit=" + unit,
            "-E", "PATH=" + (Quickshell.env("PATH") || ""),
            "--", "python3", "-I", guardScript,
            "--job-name", name, "--job-kind", kind, "--job-target", target, "--job-unit", unit].concat(args)
  }

  function runJob(kind, target, args) {
    if (busy) return
    jobError = ""
    notice = ""
    confirmDangerous = false
    var unit = "plugin-guard-job-" + Date.now()
    launchedUnit = unit
    launchedAt = Date.now()
    now = Date.now()
    Quickshell.execDetached(unitCommand(unit, "job", kind, target, args))
  }

  // Check plugins installed or changed outside Plugin Guard. The fixed unit
  // name means a sweep that is already running is not started twice.
  // The background sweep can run model reviews and disable plugins, so it
  // is a setting (on by default) rather than unconditional.
  readonly property bool autoScan: String(setting("autoScan", true)) !== "false"

  function startSweep() {
    if (!autoScan) return
    Quickshell.execDetached(unitCommand("plugin-guard-sweep", "sweep", "sweep", "", ["sweep"]))
  }

  function readState(file) {
    try {
      var data = JSON.parse(String(file.text() || ""))
      return data && typeof data === "object" ? data : ({})
    } catch (e) {
      return ({})
    }
  }

  function syncJob() {
    var st = readState(jobFile)
    var first = !jobStateLoaded
    jobStateLoaded = true
    jobState = st
    if (!st.id || st.id === handledJobId || st.state === "running") return
    // A job that finished before this panel was created (a reload) is shown
    // only if it just finished; older results are history.
    var finished = Date.parse(st.finishedAt || "")
    if (first && (isNaN(finished) || Date.now() - finished > 20000)) {
      handledJobId = st.id
      return
    }
    handledJobId = st.id
    if (launchedUnit === st.unit) launchedUnit = ""
    if (st.state === "error") jobError = String(st.error || "")
    else if (st.state === "done") handleDone(st.kind, st.target, st.result)
    refreshStatus()
  }

  function syncSweep() {
    var wasSweeping = sweeping
    sweepState = readState(sweepFile)
    if (wasSweeping && !alive(sweepState)) refreshStatus()
  }

  function scanUrl() {
    var url = urlField.text.trim()
    if (url === "") return
    runJob("scan", url, ["scan", url])
  }

  function installReport(enable) {
    if (!report) return
    if (report.verdict === "dangerous" && !confirmDangerous) {
      confirmDangerous = true
      return
    }
    var args = ["install", report.scanId]
    if (enable) args.push("--enable")
    if (report.verdict === "dangerous") args.push("--force")
    runJob("install", report.plugin.name || report.plugin.id, args)
  }

  function applyUpdate() {
    if (!report) return
    if (report.verdict === "dangerous" && !confirmDangerous) {
      confirmDangerous = true
      return
    }
    var args = ["apply-update", report.scanId]
    if (report.verdict === "dangerous") args.push("--force")
    runJob("apply", report.plugin.name || report.plugin.id, args)
  }

  function checkPlugin(p) { runJob("check", p.name || p.id, ["check", p.id]) }
  function checkUpdate(p) { runJob("update", p.name || p.id, ["update", p.id, "--check-only"]) }
  // install.sh asks questions, so it runs in a terminal. The launcher passes
  // its arguments through bash -c, hence the quoting.
  readonly property string installScript: String(Qt.resolvedUrl("install.sh")).replace(/^file:\/\//, "")
  function runSetup() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Util.shellQuote(installScript)])
    root.close()
  }

  function dismissSetup() {
    setupNeeded = false
    Quickshell.execDetached(["python3", "-I", guardScript, "setup-state", "dismiss"])
  }

  function cancelJob() {
    if (jobState.unit && alive(jobState)) Quickshell.execDetached(["systemctl", "--user", "stop", String(jobState.unit)])
  }

  function showReport(r) {
    report = r
    view = "report"
    showInfo = false
    confirmDangerous = false
  }

  function openSavedReport(scanId) {
    if (!scanId || reportProc.running) return
    reportProc.command = ["python3", "-I", guardScript, "report", scanId, "--json"]
    reportProc.running = true
  }

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshModels() {
    if (!modelsProc.running) modelsProc.running = true
  }

  function setModel(id) {
    if (!id || id === currentModel) return
    currentModel = id
    setModelProc.command = ["python3", "-I", guardScript, "set-model", id, "--json"]
    setModelProc.running = true
  }

  // The unit sends notifications itself; the panel shows the result.
  function handleDone(kind, target, data) {
    if (!data) return
    if (kind === "scan" || kind === "check") {
      showReport(data)
    } else if (kind === "update") {
      if (data.upToDate) notice = strings.t("report.upToDate").arg(target)
      else if (data.report) showReport(data.report)
    } else if (kind === "install") {
      notice = (data.enabled ? strings.t("done.installedEnabled") : strings.t("done.installed")).arg(target)
      view = "home"
      report = null
      urlField.text = ""
    } else if (kind === "apply") {
      notice = strings.t("done.updated").arg(target)
      view = "home"
      report = null
    }
  }

  FileView {
    id: jobFile
    path: root.stateDir + "/job.json"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.syncJob()
    onLoadFailed: root.jobStateLoaded = true
  }

  FileView {
    id: sweepFile
    path: root.stateDir + "/sweep.json"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.syncSweep()
  }

  // Watches miss a file that is created after the watch starts, so read the
  // state files directly while something is running.
  Timer {
    interval: 1500
    repeat: true
    running: root.busy || root.sweeping
    onTriggered: {
      root.now = Date.now()
      jobFile.reload()
      sweepFile.reload()
    }
  }

  // Each plugin change recreates this panel, so a sweep on creation checks
  // whatever just changed; the timer catches changes made while the shell
  // was not running.
  Timer {
    interval: 3000
    running: true
    onTriggered: root.startSweep()
  }

  Timer {
    interval: 10 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.startSweep()
  }

  Process {
    id: statusProc
    command: ["python3", "-I", root.guardScript, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || ""))
          root.plugins = Array.isArray(data.plugins) ? data.plugins : []
          root.setupNeeded = data.setupNeeded === true
        } catch (e) {}
      }
    }
  }

  Process {
    id: modelsProc
    command: ["python3", "-I", root.guardScript, "models", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || ""))
          root.models = Array.isArray(data.models) ? data.models : []
          root.currentModel = String(data.current || "")
        } catch (e) {}
      }
    }
  }

  Process {
    id: setModelProc
    onExited: root.refreshModels()
  }

  Process {
    id: reportProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || ""))
          if (data && data.scanId) root.showReport(data)
        } catch (e) {}
      }
    }
  }

  // The bar icon reflects installed plugins from startup, not just after the
  // popup first opens; refresh occasionally to pick up installs made elsewhere.
  Timer {
    interval: 10 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshStatus() }
    // Open a saved report by scan id or plugin id.
    function report(key: string): void {
      if (!root.opened) root.open()
      root.openSavedReport(key)
    }
  }

  // ---- Small reusable pieces.
  component Label: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
  }

  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    font.bold: true
  }

  component ActionButton: Button {
    foreground: root.fg
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    bordered: true
    opacity: enabled ? 1.0 : 0.4
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Math.min(column.implicitHeight, Style.space(680)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus
      onCloseRequested: root.view === "report" ? (root.view = "home") : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(12)

          // ---- Header: title and model picker.
          Item {
            width: parent.width
            height: Math.max(titleText.implicitHeight, modelPicker.implicitHeight)

            Text {
              id: titleText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("title")
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Dropdown {
              id: modelPicker
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(Style.space(260), parent.width - titleText.implicitWidth - Style.space(12))
              showLabel: false
              foreground: root.fg
              fontFamily: root.fontFamily
              enabled: !root.busy && root.models.length > 0
              value: root.currentModel
              options: root.models.length > 0
                ? root.models.map(function(m) { return { value: m.id, label: m.label } })
                : [{ value: "", label: strings.t("model.none") }]
              onChanged: function(value) { root.setModel(value) }
            }
          }

          // ---- Job status.
          Item {
            width: parent.width
            height: visible ? Math.max(jobText.implicitHeight, cancelButton.implicitHeight) : 0
            visible: root.busy

            Label {
              id: jobText
              anchors.left: parent.left
              anchors.right: cancelButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("check.elapsed").arg(root.jobMessage || root.jobTarget).arg(Commons.I18n.formatNumber(root.elapsed))
              color: root.dim
              elide: Text.ElideRight
              wrapMode: Text.NoWrap
            }

            ActionButton {
              id: cancelButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("check.cancel")
              onClicked: root.cancelJob()
            }
          }

          Label {
            width: parent.width
            visible: root.sweeping
            text: strings.t("sweep.running").arg(String(root.sweepState.message || ""))
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
          }

          Label {
            width: parent.width
            visible: text !== ""
            text: root.jobError
            color: Color.urgent
          }

          Label {
            width: parent.width
            visible: text !== "" && !root.busy
            text: root.notice
            color: root.dim
          }

          // ---- Home: scan box and installed plugins.
          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: root.view === "home"

            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.setupNeeded

              Caption { text: strings.t("setup.heading").toUpperCase() }

              Label {
                width: parent.width
                text: strings.t("setup.body")
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                spacing: Style.space(6)

                ActionButton {
                  text: strings.t("setup.run")
                  onClicked: root.runSetup()
                }

                ActionButton {
                  text: strings.t("setup.dismiss")
                  onClicked: root.dismissSetup()
                }
              }

              PanelSeparator { foreground: root.fg }
            }

            Caption { text: strings.t("check.heading").toUpperCase() }

            Item {
              width: parent.width
              height: Math.max(urlField.implicitHeight, scanButton.implicitHeight)

              TextField {
                id: urlField
                anchors.left: parent.left
                anchors.right: scanButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: strings.t("check.placeholder")
                foreground: root.fg
                font.family: root.fontFamily
                enabled: !root.busy
                onAccepted: root.scanUrl()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }

              ActionButton {
                id: scanButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("check.scan")
                enabled: !root.busy && urlField.text.trim() !== "" && root.models.length > 0
                onClicked: root.scanUrl()
              }
            }

            PanelSeparator { foreground: root.fg }

            Caption { text: strings.t("installed.heading").toUpperCase() }

            Label {
              visible: root.plugins.length === 0
              text: strings.t("installed.none")
              color: root.dim
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.plugins

                Item {
                  id: pluginRow
                  required property var modelData
                  width: parent.width
                  height: Math.max(rowText.implicitHeight, rowButtons.implicitHeight)

                  readonly property string stateLabel: modelData.state === "scanned"
                    ? strings.t("verdict." + modelData.verdict)
                    : strings.t("state." + modelData.state)
                  readonly property color stateColor: modelData.state === "scanned"
                    ? root.verdictColor(modelData.verdict) : root.dim

                  Column {
                    id: rowText
                    anchors.left: parent.left
                    anchors.right: rowButtons.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Label {
                      width: parent.width
                      text: pluginRow.modelData.name
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: (pluginRow.modelData.state === "scanned" ? root.verdictGlyph(pluginRow.modelData.verdict) + " " : "")
                        + pluginRow.stateLabel
                        + (pluginRow.modelData.model ? "  ·  " + pluginRow.modelData.model : "")
                      color: pluginRow.stateColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Row {
                    id: rowButtons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)

                    ActionButton {
                      text: strings.t("installed.report")
                      visible: pluginRow.modelData.scanId !== ""
                      enabled: !reportProc.running
                      onClicked: root.openSavedReport(pluginRow.modelData.scanId)
                    }

                    ActionButton {
                      text: strings.t("installed.scan")
                      enabled: !root.busy
                      onClicked: root.checkPlugin(pluginRow.modelData)
                    }

                    ActionButton {
                      text: strings.t("installed.update")
                      visible: pluginRow.modelData.git
                      enabled: !root.busy
                      onClicked: root.checkUpdate(pluginRow.modelData)
                    }
                  }
                }
              }
            }
          }

          // ---- Report.
          Column {
            id: reportView
            width: parent.width
            spacing: Style.space(10)
            visible: root.view === "report" && root.report !== null

            readonly property var r: root.report || ({})
            readonly property var plugin: r.plugin || ({})
            readonly property var source: r.source || ({})
            readonly property var findings: r.findings || []
            // Minor items (informational, or low-severity pattern matches such
            // as "makes network requests") are context, shown on request.
            function isMinor(f) { return f.severity === "info" || (f.source !== "model" && f.severity === "low") }
            readonly property var shownFindings: findings.filter(function(f) { return root.showInfo || !reportView.isMinor(f) })
            readonly property int infoCount: findings.filter(function(f) { return reportView.isMinor(f) }).length
            readonly property var hosts: {
              var nd = r.networkDestinations || {}
              var purposes = {}
              ;(nd.model || []).forEach(function(d) { purposes[d.host] = d.purpose })
              var all = Object.keys(purposes)
              ;(nd.static || []).forEach(function(d) { if (all.indexOf(d.host) < 0) all.push(d.host) })
              all.sort()
              return all.map(function(h) { return purposes[h] ? h + " — " + purposes[h] : h })
            }
            readonly property bool isUpdate: source.type === "update"

            Row {
              spacing: Style.space(10)
              width: parent.width

              Text {
                textFormat: Text.PlainText
                text: root.verdictGlyph(reportView.r.verdict)
                color: root.verdictColor(reportView.r.verdict)
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(60)
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  text: reportView.r.verdict ? strings.t("verdict." + reportView.r.verdict).toUpperCase() : ""
                  color: root.verdictColor(reportView.r.verdict)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  font.letterSpacing: 1
                }

                Label {
                  width: parent.width
                  text: (reportView.plugin.name || reportView.plugin.id || "") + "  " + (reportView.plugin.version || "")
                  font.bold: true
                  elide: Text.ElideRight
                  wrapMode: Text.NoWrap
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: (reportView.source.url || reportView.source.path || reportView.source.pluginId || "")
                    + (reportView.r.commit ? " @ " + root.shortCommit(reportView.r.commit) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.Wrap
              text: (reportView.r.model ? strings.t("report.model").arg(reportView.r.model.label) + "  ·  " : "")
                + strings.t("report.static").arg(strings.t("verdict." + (reportView.r.staticVerdict || "safe")))
                  .arg(reportView.r.modelVerdict ? strings.t("verdict." + reportView.r.modelVerdict) : strings.t("report.notRun"))
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Label {
              width: parent.width
              visible: !!reportView.r.modelError
              text: strings.t("report.modelFailed").arg(reportView.r.modelError || "")
              color: Color.urgent
              font.pixelSize: Style.font.bodySmall
            }

            Label {
              width: parent.width
              visible: text !== ""
              text: reportView.r.summary || ""
            }

            Label {
              width: parent.width
              visible: text !== ""
              text: reportView.r.purposeMatch ? strings.t("report.purpose") + ": " + reportView.r.purposeMatch : ""
              color: root.dim
              font.pixelSize: Style.font.bodySmall
            }

            PanelSeparator { foreground: root.fg }

            Caption { text: strings.t("report.findings").toUpperCase() }

            Label {
              visible: reportView.shownFindings.length === 0
              text: strings.t("report.noFindings")
              color: root.dim
            }

            Repeater {
              model: reportView.shownFindings

              Column {
                id: findingRow
                required property var modelData
                width: reportView.width
                spacing: Style.space(2)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    id: sevText
                    textFormat: Text.PlainText
                    text: String(findingRow.modelData.severity).toUpperCase()
                    color: root.severityColor(findingRow.modelData.severity)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    width: Style.space(64)
                  }

                  Label {
                    width: parent.width - sevText.width - Style.space(6)
                    text: findingRow.modelData.title + (findingRow.modelData.source === "model" ? "" : "  ·  static")
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  x: Style.space(70)
                  width: parent.width - x
                  text: findingRow.modelData.file + (findingRow.modelData.line ? ":" + findingRow.modelData.line : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                  visible: text !== ""
                }

                Text {
                  textFormat: Text.PlainText
                  x: Style.space(70)
                  width: parent.width - x
                  text: findingRow.modelData.detail || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                  maximumLineCount: 4
                  elide: Text.ElideRight
                  visible: text !== ""
                }
              }
            }

            ActionButton {
              visible: reportView.infoCount > 0 && !root.showInfo
              text: strings.tn("report.infoHidden", reportView.infoCount).arg(Commons.I18n.formatNumber(reportView.infoCount))
              onClicked: root.showInfo = true
            }

            Caption {
              visible: reportView.hosts.length > 0
              text: strings.t("report.network").toUpperCase()
            }

            Label {
              width: parent.width
              visible: reportView.hosts.length > 0
              text: reportView.hosts.join("\n")
              font.pixelSize: Style.font.bodySmall
            }

            Label {
              width: parent.width
              readonly property int count: reportView.r.files && reportView.r.files.notReviewed ? reportView.r.files.notReviewed.length : 0
              visible: count > 0
              text: strings.tn("report.notReviewed", count).arg(Commons.I18n.formatNumber(count))
                + (count > 0 ? ": " + reportView.r.files.notReviewed.slice(0, 6).join(", ") + (count > 6 ? " …" : "") : "")
              color: root.dim
              font.pixelSize: Style.font.caption
            }

            PanelSeparator { foreground: root.fg }

            Label {
              width: parent.width
              visible: root.confirmDangerous
              text: strings.t("report.confirmAnyway")
              color: Color.urgent
              font.pixelSize: Style.font.bodySmall
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              ActionButton {
                text: strings.t("report.back")
                onClicked: { root.view = "home"; root.confirmDangerous = false }
              }

              ActionButton {
                visible: !!reportView.r.installable
                enabled: !root.busy
                text: reportView.r.verdict === "dangerous" ? strings.t("report.installAnyway") : strings.t("report.install")
                onClicked: root.installReport(false)
              }

              ActionButton {
                visible: !!reportView.r.installable && reportView.r.verdict !== "dangerous"
                enabled: !root.busy
                text: strings.t("report.installEnable")
                onClicked: root.installReport(true)
              }

              ActionButton {
                visible: reportView.isUpdate && !root.plugins.some(function(p) { return p.id === reportView.source.pluginId && p.commit === reportView.r.commit })
                enabled: !root.busy
                text: reportView.r.verdict === "dangerous" ? strings.t("report.applyAnyway") : strings.t("report.applyUpdate")
                onClicked: root.applyUpdate()
              }
            }
          }
        }
      }
    }
  }
}
