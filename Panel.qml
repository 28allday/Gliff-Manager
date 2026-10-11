import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Gliff-Manager: a bar icon and dropdown for gliff remote desktop sessions.
//
// Everything that touches the system lives in gliff-manager.sh beside this
// file, so each step can be run by hand when something looks wrong. The panel
// asks it for status twice per open:
//
//   status fast   no ssh: saved machines, last checks, running windows (~0.1s)
//   status full   checks every machine over ssh, in parallel
//
// While open, the fast pass repeats so connect/disconnect shows up promptly.
// While closed, only `live` runs, slowly, to colour the bar icon.
Panel {
  id: root
  moduleName: "nosignal.gliff-manager"
  ipcTarget: "nosignal.gliff-manager"
  manageIpc: false

  readonly property string scriptPath: String(Qt.resolvedUrl("gliff-manager.sh")).replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------------ data
  property var localInfo: null        // this computer: gliff version, GPUs, video choice
  property var machines: []           // [{ target, mode, probe, live: [{pid, mode}] }]
  property var suggestions: []        // [{ name, dns, tailscaleSsh }]
  property var others: []             // gliff windows the manager did not open
  property int hiddenPeers: 0         // tailnet machines hidden from the list
  property int hiddenMachines: 0      // your machines hidden from the list
  property int moreMachines: 0        // machines past the list's limit
  property int moreSuggestions: 0     // tailnet machines past the list's limit
  property bool loaded: false
  property bool checking: false
  property int liveCount: 0
  property string actionStatus: ""
  property bool actionError: false

  // ---------------------------------------------------------------- cursor
  // One flat cursor over machines, then tailnet suggestions, then the video
  // row, so arrow keys walk the whole panel.
  property int cursorIndex: 0
  property bool cursorActive: false
  property bool editing: false

  readonly property int videoIndex: machines.length + suggestions.length
  readonly property int namesIndex: videoIndex + 1
  readonly property int cursorCount: namesIndex + 1

  function cursorOn(i) { return root.cursorActive && root.cursorIndex === i }

  function moveCursor(dy) {
    if (dy === 0) return
    root.cursorIndex = Math.max(0, Math.min(root.cursorCount - 1, root.cursorIndex + dy))
    root.scrollCursorIntoView()
  }

  function activateCursor() {
    var i = root.cursorIndex
    if (i < root.machines.length) root.primaryAction(root.machines[i])
    else if (i < root.videoIndex) root.useSuggestion(root.suggestions[i - root.machines.length])
    else if (i === root.videoIndex) root.cycleVideo()
    else root.toggleShortNames()
  }

  function cursorMachine() {
    return root.cursorIndex < root.machines.length ? root.machines[root.cursorIndex] : null
  }

  // ------------------------------------------------------------ machine model

  function hostOf(target) {
    var at = target.indexOf("@")
    return at >= 0 ? target.slice(at + 1) : target
  }
  function userOf(target) {
    var at = target.indexOf("@")
    return at >= 0 ? target.slice(0, at) : ""
  }
  function shortHost(target) {
    return root.hostOf(target).split(".")[0]
  }

  // What a launch in "auto" will pick: the private headless screen when the
  // machine has nothing plugged in, otherwise a mirror of what is on its screen.
  function resolvedMode(m) {
    if (m.mode !== "auto") return m.mode
    if (!m.probe || m.probe.reach !== "ok") return "auto"
    return m.probe.displays > 0 ? "mirror" : "headless"
  }

  function modeLabel(mode) {
    if (mode === "headless") return "Headless"
    if (mode === "mirror") return "Mirror"
    if (mode.indexOf("output:") === 0) return "Screen " + mode.slice(7)
    return "Auto"
  }

  function modeChip(m) {
    if (m.mode === "auto") {
      var r = root.resolvedMode(m)
      return r === "auto" ? "AUTO" : "AUTO · " + root.modeLabel(r).toUpperCase()
    }
    return root.modeLabel(m.mode).toUpperCase()
  }

  // Auto, headless, mirror, then each screen the machine reported.
  function nextMode(m) {
    var cycle = ["auto", "headless", "mirror"]
    var outs = (m.probe && m.probe.outputs) ? m.probe.outputs : []
    for (var i = 0; i < outs.length; i++) cycle.push("output:" + outs[i])
    var at = cycle.indexOf(m.mode)
    return cycle[(at + 1) % cycle.length]
  }

  // One verdict per machine, from the most basic problem up. Each carries the
  // fix the panel can offer for it, if there is one.
  function machineState(m) {
    var p = m.probe
    if (m.live && m.live.length > 0)
      return { tone: "live", text: "Connected · " + root.modeLabel(m.live[0].mode), fix: "" }
    if (!p) return { tone: "dim", text: root.checking ? "Checking…" : "Not checked yet", fix: "" }
    if (p.reach === "tailscale-check")
      return { tone: "warn", text: "Tailscale wants you to sign in again", fix: "signin" }
    if (p.reach === "offline")
      return { tone: "dim", text: "Offline or not answering ssh", fix: "" }
    if (p.reach === "denied")
      return { tone: "warn", text: "Login refused for " + (root.userOf(m.target) || "this user"), fix: "" }
    if (p.reach === "hostkey")
      return { tone: "warn", text: "Host key not saved yet", fix: "trust" }
    if (p.reach === "hostkey-changed")
      return { tone: "warn", text: "Host key changed — booted into another OS?", fix: "trust" }
    if (p.hyprOwner !== "" && p.hyprOwner !== p.user)
      return { tone: "warn", text: "Hyprland runs as " + p.hyprOwner + ", not " + p.user, fix: "switch-user" }
    if (!p.session && p.hyprOwner === "")
      return { tone: "warn", text: "No Hyprland session running", fix: "" }
    if (p.gliff === "")
      return { tone: "warn", text: "gliff is not installed there", fix: "install" }
    var bits = [p.arch, p.channel].filter(function(s) { return s })
    var text = "Ready · " + bits.join(" · ")
    if (root.localInfo && root.localInfo.version && p.gliff !== root.localInfo.version)
      text = "Ready · gliff " + p.gliff + " there, " + root.localInfo.version + " here"
    if (!p.xdg && !p.wrapped)
      return { tone: "ok", text: text, fix: "fix-session" }
    return { tone: "ok", text: text, fix: "" }
  }

  function fixLabel(fix, m) {
    if (fix === "install") return "Install gliff on " + root.shortHost(m.target)
    if (fix === "fix-session") return "Install the session fix so plain gliff works too"
    if (fix === "trust") return "Log in once in a terminal to save its host key"
    if (fix === "signin") return "Sign in to Tailscale in your browser so ssh is allowed again"
    if (fix === "switch-user") return "Use " + m.probe.hyprOwner + "@" + root.hostOf(m.target) + " instead"
    return ""
  }

  function toneColor(tone) {
    if (tone === "live") return root.accent
    if (tone === "warn") return root.urgent
    if (tone === "ok") return root.foreground
    return root.dim
  }

  function statusGlyph(tone) {
    if (tone === "live") return "󰢹"
    if (tone === "warn") return "󰀦"
    if (tone === "ok") return "󰍹"
    return "󰍺"
  }

  // ---------------------------------------------------------------- actions

  property var queue: []

  property bool fullAfterQueue: false

  function run(args, label, full) {
    if (full) root.fullAfterQueue = true
    root.queue = root.queue.concat([{ args: args, label: label }])
    if (!actionProc.running) root.runNext()
  }

  function runNext() {
    if (root.queue.length === 0) return
    var next = root.queue[0]
    root.queue = root.queue.slice(1)
    root.actionStatus = next.label
    root.actionError = false
    actionProc.command = ["sh", root.scriptPath].concat(next.args)
    actionProc.running = true
  }

  function primaryAction(m) {
    if (!m) return
    if (m.live && m.live.length > 0) {
      root.run(["disconnect", m.target], "Disconnecting " + root.shortHost(m.target))
      return
    }
    var st = root.machineState(m)
    if (st.tone === "warn" && st.fix !== "") { root.applyFix(m); return }
    // A window already open in the same mode gets this machine as a tab;
    // gliff can only do that by reopening, so its tabs reconnect.
    var mode = root.resolvedMode(m)
    var sharing = root.machines.filter(function(o) {
      return o.live && o.live.length > 0 && o.live[0].mode === mode
    })
    root.run(["connect", m.target], sharing.length > 0
      ? "Adding " + root.shortHost(m.target) + " as a tab — the window reopens and its tabs reconnect"
      : "Connecting " + root.shortHost(m.target))
  }

  function applyFix(m) {
    if (!m) return
    var fix = root.machineState(m).fix
    if (fix === "switch-user") {
      var t = m.probe.hyprOwner + "@" + root.hostOf(m.target)
      root.run(["add", t], "Added " + t, true)
      root.run(["forget", m.target], "Switched to " + t, true)
    } else if (fix !== "") {
      root.run([fix, m.target], root.fixLabel(fix, m) + " — finish in the terminal")
    }
  }

  function cycleMode(m) {
    if (!m) return
    root.run(["set-mode", m.target, root.nextMode(m)], "")
  }

  function forget(m) {
    if (!m) return
    root.run(["forget", m.target], "Hid " + root.shortHost(m.target) + " — \"show them again\" below the list brings it back")
  }

  property bool namesBusy: false

  function toggleShortNames() {
    if (!root.localInfo || root.namesBusy) return
    var on = !root.localInfo.shortNames
    root.namesBusy = true
    root.run(["short-names", on ? "on" : "off"], on
      ? "Short names on: new gliff windows show studio, not me@studio.example.net"
      : "Short names off; your ssh config is back as it was")
  }

  function hidePeer(p) {
    if (!p) return
    root.run(["hide-peer", p.dns], "Hid " + p.dns.split(".")[0] + " from the tailnet list")
  }

  function cycleVideo() {
    var order = ["auto", "cpu", "gpu"]
    var cur = root.localInfo ? root.localInfo.video : "auto"
    root.run(["set-video", order[(order.indexOf(cur) + 1) % order.length]], "")
  }

  // A tailnet peer arrives without a user name, and guessing one is how a
  // login gets refused. Fill in the host and leave the cursor before the @.
  function useSuggestion(s) {
    if (!s) return
    addField.text = "@" + s.dns
    root.editing = true
    addField.forceActiveFocus()
    addField.cursorPosition = 0
  }

  function addMachine() {
    var t = addField.text.trim()
    if (!/^[A-Za-z0-9._-]+@[A-Za-z0-9][A-Za-z0-9._-]*$/.test(t)) {
      root.actionStatus = "Type it as user@host"
      root.actionError = true
      return
    }
    addField.text = ""
    root.editing = false
    keyCatcher.forceActiveFocus()
    root.run(["add", t], "Added " + t + ", checking it", true)
  }

  function refresh(full) {
    if (statusProc.running) { root.pendingFull = root.pendingFull || full; return }
    root.checking = full
    statusProc.depth = full ? "full" : "fast"
    statusProc.running = true
  }
  property bool pendingFull: false

  function parseStatus(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    if (!data || typeof data !== "object") return
    root.localInfo = data.local || null
    // The helper caps these too; the panel keeps its own limits regardless.
    var machines = Array.isArray(data.machines) ? data.machines : []
    var suggestions = Array.isArray(data.suggestions) ? data.suggestions : []
    root.machines = machines.slice(0, 64)
    root.moreMachines = (Number(data.moreMachines) || 0) + machines.length - root.machines.length
    root.suggestions = suggestions.slice(0, 8)
    root.moreSuggestions = suggestions.length - root.suggestions.length
    root.others = Array.isArray(data.others) ? data.others.slice(0, 64) : []
    root.hiddenPeers = Number(data.hiddenPeers) || 0
    root.hiddenMachines = Number(data.hiddenMachines) || 0
    var n = root.others.length
    for (var i = 0; i < root.machines.length; i++) n += (root.machines[i].live || []).length
    root.liveCount = n
    root.loaded = true
    if (root.cursorIndex >= root.cursorCount) root.cursorIndex = Math.max(0, root.cursorCount - 1)
  }

  function scrollCursorIntoView() {
    var item = null
    var i = root.cursorIndex
    if (i < root.machines.length) item = machineColumn.children[i]
    else if (i < root.videoIndex) item = suggestionColumn.children[i - root.machines.length]
    else if (i === root.videoIndex) item = videoRow
    else item = namesRow
    if (!item || !panelFlick) return
    Qt.callLater(function() {
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(Math.max(0, panelFlick.contentHeight - panelFlick.height),
                                       bottom + margin - panelFlick.height)
    })
  }

  // ------------------------------------------------------------- processes

  Process {
    id: statusProc
    property string depth: "fast"
    command: ["sh", root.scriptPath, "status", depth]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseStatus(text)
        var wasFast = statusProc.depth === "fast"
        root.checking = false
        if (root.pendingFull) {
          root.pendingFull = false
          Qt.callLater(function() { root.refresh(true) })
        } else if (wasFast && root.opened && root.firstPass) {
          root.firstPass = false
          Qt.callLater(function() { root.refresh(true) })
        }
      }
    }
  }
  property bool firstPass: false

  Process {
    id: actionProc
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(code) {
      if (code !== 0) {
        var msg = String(actionErr.text || "").trim().split("\n")[0].replace(/^gliff-manager: /, "").slice(0, 300)
        root.actionStatus = msg !== "" ? msg : "That did not work (exit " + code + ")"
        root.actionError = true
        root.queue = []
      } else if (root.queue.length === 0) {
        root.refresh(root.fullAfterQueue)
        root.fullAfterQueue = false
        clearStatus.restart()
      }
      root.namesBusy = false
      root.runNext()
    }
  }

  Process {
    id: liveProc
    command: ["sh", root.scriptPath, "live"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var l = JSON.parse(text)
          if (Array.isArray(l)) root.liveCount = l.length
        } catch (e) {}
      }
    }
  }

  Timer {
    id: clearStatus
    interval: 6000
    onTriggered: if (!root.actionError) root.actionStatus = ""
  }

  // Open: the cheap pass every few seconds. Closed: just the window count.
  Timer {
    interval: root.opened ? 4000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.opened) root.refresh(false)
      else if (!liveProc.running) liveProc.running = true
    }
  }

  onOpenedChanged: if (opened) {
    root.cursorActive = false
    root.editing = false
    root.firstPass = true
    if (panelFlick) panelFlick.contentY = 0
    root.refresh(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰢹"
    tooltipText: root.liveCount > 0
      ? "Gliff-Manager · " + root.liveCount + (root.liveCount === 1 ? " session" : " sessions")
      : "Gliff-Manager"
    foreground: root.liveCount > 0 ? Color.accent : root.barForeground
    onPressed: function(code) {
      if (code === Qt.RightButton) root.refresh(true)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: {
        if (!root.cursorActive) return
        var i = root.cursorIndex
        if (i < root.machines.length) root.forget(root.machines[i])
        else if (i < root.videoIndex) root.hidePeer(root.suggestions[i - root.machines.length])
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "r") root.refresh(true)
        else if (k === "m" && root.cursorActive) root.cycleMode(root.cursorMachine())
        else if (k === "f" && root.cursorActive) root.applyFix(root.cursorMachine())
        else if (k === "a") { root.editing = true; addField.forceActiveFocus() }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Gliff-Manager"
            meta: !root.loaded ? "Loading"
              : root.checking ? "Checking machines"
              : root.machines.length + (root.machines.length === 1 ? " machine" : " machines")
                + " · " + root.liveCount + " connected"
            detail: root.localInfo && root.localInfo.installed ? root.localInfo.version.replace(/-\d+$/, "") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰢹"
                color: root.liveCount > 0 ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.localInfo !== null && !root.localInfo.installed
            width: parent.width
            text: "gliff is not installed on this computer. Install it with: omarchy pkg add gliff"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.actionStatus !== ""
            width: parent.width
            text: root.actionStatus
            color: root.actionError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "MACHINES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: root.loaded && root.machines.length === 0
              width: parent.width
              text: "No machines yet. Add one below as user@host."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Column {
              id: machineColumn
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.machines
                MachineRow {
                  required property var modelData
                  required property int index
                  width: machineColumn.width
                  machine: modelData
                  rowIndex: index
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.moreMachines > 0
              width: parent.width
              text: root.moreMachines + (root.moreMachines === 1 ? " more machine" : " more machines")
                + " not shown: the list holds 64. Hide some to see the rest."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.hiddenMachines > 0
              text: root.hiddenMachines + " hidden · show them again"
              color: showHiddenMachines.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.underline: showHiddenMachines.containsMouse

              MouseArea {
                id: showHiddenMachines
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.run(["show-machines"], "Showing every hidden machine again", true)
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.others.length > 0
              width: parent.width
              text: root.others.length + (root.others.length === 1 ? " other gliff window" : " other gliff windows")
                + " open, started outside the manager"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: addField
                Layout.fillWidth: true
                placeholderText: "user@host"
                foreground: root.foreground
                font.family: root.fontFamily
                onActiveFocusChanged: root.editing = activeFocus
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    addField.text = ""
                    root.editing = false
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.addMachine()
                    event.accepted = true
                  }
                }
              }

              PanelActionButton {
                iconText: "󰐕"
                tooltipText: "Add machine"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.addMachine()
              }
            }
          }

          PanelSeparator {
            visible: root.suggestions.length > 0 || root.hiddenPeers > 0
            foreground: root.foreground
          }

          Column {
            visible: root.suggestions.length > 0 || root.hiddenPeers > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "ON YOUR TAILNET"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: suggestionColumn
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.suggestions
                SuggestionRow {
                  required property var modelData
                  required property int index
                  width: suggestionColumn.width
                  peer: modelData
                  rowIndex: root.machines.length + index
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.moreSuggestions > 0
              width: parent.width
              text: root.moreSuggestions + " more not shown · add one by name above, or hide some"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.hiddenPeers > 0
              text: root.hiddenPeers + " hidden · show them again"
              color: showHidden.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.underline: showHidden.containsMouse

              MouseArea {
                id: showHidden
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.run(["show-peers"], "Showing every tailnet machine again")
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "THIS COMPUTER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              id: videoRow
              width: parent.width
              hasCursor: root.cursorOn(root.videoIndex)
              foreground: root.foreground
              implicitHeight: videoContent.implicitHeight + Style.spacing.rowPaddingX

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.cursorIndex = root.videoIndex }
                onClicked: root.cycleVideo()
              }

              ColumnLayout {
                id: videoContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(1)

                RowLayout {
                  Layout.fillWidth: true
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Video decoding"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: !root.localInfo ? ""
                      : (root.localInfo.video === "auto" ? "AUTO · " : "") + root.localInfo.effectiveVideo.toUpperCase()
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: {
                    var l = root.localInfo
                    if (!l) return ""
                    if (l.video === "cpu") return "Always on the processor. Click to switch."
                    if (l.video === "gpu") return "Always on the graphics card. Click to switch."
                    if (l.hybrid) return l.gpus + ": decoding on the processor, since the GPU hand-off between the two shows a black picture."
                    if (l.envVideo) return "GLIFF_VIDEO=" + l.envVideo + " is set in your environment, so gliff follows that."
                    return (l.gpus || "One graphics chip") + ": gliff picks the graphics card."
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          CursorSurface {
            id: namesRow
            width: parent.width
            hasCursor: root.cursorOn(root.namesIndex)
            foreground: root.foreground
            implicitHeight: namesContent.implicitHeight + Style.spacing.rowPaddingX

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: { root.cursorActive = true; root.cursorIndex = root.namesIndex }
              onClicked: root.toggleShortNames()
            }

            RowLayout {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              ColumnLayout {
                id: namesContent
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Short tab names"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Tabs read \"studio\" instead of \"me@studio.example.net\". Adds one line to ~/.ssh/config; switching off removes it."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              ToggleSwitch {
                checked: root.localInfo ? root.localInfo.shortNames === true : false
                busy: root.namesBusy
                interactive: false
                cursorRing: false
                foreground: root.foreground
                Layout.alignment: Qt.AlignVCenter
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Enter connect · M mode · F fix · Del hide · R recheck · A add · Shift+Esc in gliff frees your keys"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component MachineRow: CursorSurface {
    id: row
    property var machine: null
    property int rowIndex: 0
    readonly property var verdict: machine ? root.machineState(machine) : ({ tone: "dim", text: "", fix: "" })
    readonly property bool live: machine && machine.live && machine.live.length > 0

    hasCursor: root.cursorOn(rowIndex)
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = row.rowIndex }
      onClicked: root.primaryAction(row.machine)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.statusGlyph(row.verdict.tone)
        color: root.toneColor(row.verdict.tone)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: row.machine ? root.shortHost(row.machine.target) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: row.machine ? root.userOf(row.machine.target) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          // The mode reads as a label and changes on click, so what a
          // connect will do is visible right where you change it.
          BorderSurface {
            id: modeChip
            implicitWidth: modeText.implicitWidth + Style.space(10)
            implicitHeight: modeText.implicitHeight + Style.space(4)
            radius: Style.cornerRadius
            color: modeMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
            borderSpec: Border.controlSpec(modeMouse.containsMouse ? "hover-cursor" : "normal", root.foreground, root.accent)

            Text {
              id: modeText
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: row.machine ? root.modeChip(row.machine) : ""
              color: modeMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              id: modeMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: { root.cursorActive = true; root.cursorIndex = row.rowIndex }
              onClicked: root.cycleMode(row.machine)
            }

            PanelToolTip {
              visible: modeMouse.containsMouse
              text: "Click to change: Auto picks headless when nothing is plugged in, mirror when a display is"
              fontFamily: root.fontFamily
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.verdict.text
          color: row.verdict.tone === "warn" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: row.verdict.fix !== ""
        iconText: "󰖷"
        tooltipText: row.machine ? root.fixLabel(row.verdict.fix, row.machine) : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.applyFix(row.machine)
      }

      PanelActionButton {
        iconText: row.live ? "󰅙" : "󰐊"
        tooltipText: row.live ? "Disconnect" : "Connect"
        foreground: root.foreground
        hoverColor: row.live ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.primaryAction(row.machine)
      }

      PanelActionButton {
        visible: !row.live
        iconText: "󰈉"
        tooltipText: "Hide from this list"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.forget(row.machine)
      }
    }
  }

  component SuggestionRow: CursorSurface {
    id: srow
    property var peer: null
    property int rowIndex: 0

    hasCursor: root.cursorOn(rowIndex)
    foreground: root.foreground
    implicitHeight: srowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = srow.rowIndex }
      onClicked: root.useSuggestion(srow.peer)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "󰒍"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: srowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: srow.peer ? (srow.peer.dns.split(".")[0]) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: srow.peer ? (srow.peer.tailscaleSsh ? "Linux · Tailscale SSH · click, then type the user" : "Linux · click, then type the user") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰈉"
        tooltipText: "Hide from this list"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.hidePeer(srow.peer)
      }
    }
  }
}
