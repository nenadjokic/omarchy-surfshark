import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Surfshark in the bar. The official Linux client is an Electron app with no
// CLI, but it is not the app that brings the tunnel up — it is the app's helper
// daemon `surfsharkd`, listening on a unix socket in /run/user/<uid>. The
// backend in `bin/omarchy-surfshark` talks to that same daemon, so the widget
// and the app always show the same state and never fight over the connection.
//
// Anything slow — bringing the tunnel up — goes through Process; the QML only
// renders the last state it read.
Panel {
  id: root
  moduleName: "nenadjokic.surfshark"
  ipcTarget: "nenadjokic.surfshark"
  // Panel would register its own handler on this target and the two would
  // cancel each other out; here one handler carries both the panel lifecycle
  // and the tunnel actions.
  manageIpc: false

  // The script ships with the plugin, so this works without anything on PATH.
  readonly property string script: Qt.resolvedUrl("bin/omarchy-surfshark").toString().replace("file://", "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
  readonly property color selectedFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.16)

  // Same idea as the Tailscale button: the icon dims while the tunnel is down,
  // so the state reads peripherally, without parsing any text.
  readonly property color barIconColor: root.shown ? root.barForeground
                                                   : Qt.darker(root.barForeground, 1.55)

  readonly property int refreshIntervalSec: Math.max(5, setting("refreshIntervalSec", 20))
  // Which US exit the "United States" row aims at. A setting rather than a
  // constant, so the shortcut is not one person's favourite city for everyone.
  readonly property string usLocation: String(setting("usLocation", "us-nyc.prod.surfshark.com"))
  // Prefer the real city name from the loaded location list; fall back to the
  // airport-style code in the hostname before that list has arrived.
  readonly property string usLabel: {
    for (var i = 0; i < root.allLocations.length; i++)
      if (root.allLocations[i].connectionName === root.usLocation)
        return root.plain(root.allLocations[i].location)
    var m = /^us-([a-z]+)\./.exec(root.usLocation)
    return m ? m[1].toUpperCase() : "United States"
  }

  // Last state read from the backend.
  property bool configured: false
  property bool daemonReady: false
  property bool connected: false
  property string location: ""
  property string country: ""
  property string myCountry: ""
  property string myCountryCode: ""
  property string publicIp: ""
  property bool secured: false
  property var recentList: []
  property string lastError: ""

  // Every location; loaded once, the first time the panel opens. Kept in
  // memory because it is filtered on every keystroke.
  property var allLocations: []
  property string query: ""
  readonly property int maxResults: 8
  readonly property var matches: {
    var q = root.query.trim().toLowerCase()
    if (q === "") return []
    var out = []
    for (var i = 0; i < root.allLocations.length; i++) {
      var l = root.allLocations[i]
      if (String(l.location).toLowerCase().indexOf(q) !== -1
          || String(l.country).toLowerCase().indexOf(q) !== -1
          || String(l.countryCode).toLowerCase().indexOf(q) === 0)
        out.push(l)
    }
    return out
  }
  // Capped at eight so the panel cannot outgrow the screen, but the number cut
  // is shown: "united" matches three countries, and without that it would look
  // like the US has only the three cities that happen to start with A and B.
  readonly property var results: matches.slice(0, maxResults)
  readonly property int hiddenMatches: Math.max(0, matches.length - maxResults)

  // While a command runs, show the intended state rather than the real one, so
  // the switch does not snap back before the tunnel has had time to come up.
  property bool busy: false
  property int desired: -1
  readonly property bool shown: busy && desired >= 0 ? desired === 1 : connected

  // The factual state, undecorated — this is what the bar tooltip shows. The
  // panel hero rotates flavour text, so there has to be one place that always
  // says plainly where you are and whether you are protected.
  readonly property string statusPhrase: {
    if (!daemonReady) return "Surfshark daemon not running"
    if (!configured) return "Not set up"
    if (busy) return desired === 1 ? "Connecting…" : "Disconnecting…"
    if (connected) return location ? ("Protected · " + location + ", " + country) : "Protected"
    return myCountry ? ("Not protected · " + myCountry) : "Not protected"
  }

  // Rotating hero caption, like "Wiring bits / Handling packets" in the network
  // panel. Three sets, one per state: every phrase within a set means the same
  // thing, so the state stays readable even as the text changes.
  property int phraseIndex: 0
  readonly property var offPhrases: [
    "No tunnel",
    "Traffic in the clear",
    "Wide open",
    "Unshielded",
    "Nothing hidden",
    "Bare packets",
  ]
  readonly property var busyPhrases: [
    "Digging the tunnel",
    "Trading keys",
    "Shaking hands",
    "Raising the shield",
    "Wrapping packets",
  ]
  readonly property var onPhrases: [
    "Tunnel holding",
    "Packets cloaked",
    "Traffic masked",
    "Sealed end to end",
    "Shield up",
    "Hidden in the stream",
  ]
  readonly property var activePhrases: busy ? busyPhrases
                                            : (shown ? onPhrases : offPhrases)
  readonly property string statePhrase:
    activePhrases[phraseIndex % activePhrases.length]

  // Strip what would make a string stop being a string.
  //
  // A Text element left at `Text.AutoText` promotes anything that looks like
  // markup to rich text, and rich text with an embedded remote reference makes
  // the shell fetch it — inside a process that stays alive for the whole
  // session. The public IP and country come straight off the network, the
  // location and country names come out of the Surfshark app's cache, and the
  // error line is the daemon's own message, so all of them are treated as data:
  // `<` is removed outright rather than escaped, because an escaped entity only
  // renders correctly if the consumer is *already* in rich-text mode, and the
  // point is that it never should be. Control characters go too, so a crafted
  // name cannot break a one-line tooltip into several.
  //
  // This widget's own labels are pinned to `Text.PlainText` as well, but that
  // pin cannot reach `PanelHero` or the bar tooltip, which the shell owns.
  function plain(s) {
    return String(s === undefined || s === null ? "" : s)
             .replace(/[<\x00-\x1f\x7f]/g, "")
  }

  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = [root.script, "status"]
    statusProcess.running = true
  }

  function runAction(verb) {
    if (actionProcess.running) return
    root.lastError = ""
    root.busy = true
    root.desired = verb === "off" ? 0 : 1
    actionProcess.command = verb === "usa" ? [root.script, verb, root.usLocation]
                                           : [root.script, verb]
    actionProcess.running = true
  }

  function connectTo(host) {
    if (actionProcess.running || !host) return
    root.lastError = ""
    root.busy = true
    root.desired = 1
    actionProcess.command = [root.script, "connect", host]
    actionProcess.running = true
  }

  function toggleVpn() { runAction(root.shown ? "off" : "on") }

  function loadLocations() {
    if (locationsProcess.running || root.allLocations.length > 0) return
    locationsProcess.command = [root.script, "locations"]
    locationsProcess.running = true
  }

  function clearRecent() {
    if (clearProcess.running) return
    clearProcess.command = [root.script, "recent-clear"]
    clearProcess.running = true
  }

  function applyStatus(text) {
    var d
    try {
      d = JSON.parse(text)
    } catch (e) {
      return
    }
    root.configured = d.configured === true
    root.daemonReady = d.daemon === true
    root.connected = d.connected === true
    root.location = root.plain(d.location)
    root.country = root.plain(d.country)
    root.myCountry = root.plain(d.myCountry)
    root.myCountryCode = root.plain(d.myCountryCode)
    root.publicIp = root.plain(d.ip)
    root.secured = d.secured === true
    root.recentList = d.recent || []
    // Stvarnost je stigla do zeljenog stanja — prestani da je prepisujes.
    if (!actionProcess.running && root.desired >= 0
        && (root.desired === 1) === root.connected) {
      root.desired = -1
      root.busy = false
    }
  }

  Component.onCompleted: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // Only spins while the panel is open — a closed panel should animate nothing,
  // and the index resets so each opening starts from the first phrase.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.daemonReady && root.configured
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // A state change (tunnel dropped, connection started) swaps the phrase set.
  // Without this the stale index would land mid-way into the new set.
  onActivePhrasesChanged: {
    phraseSwap.stop()
    phraseIndex = 0
    if (hero) hero.metaOpacity = 1.0
  }

  onOpenedChanged: {
    if (opened) {
      loadLocations()
    } else {
      phraseSwap.stop()
      phraseIndex = 0
      query = ""
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) {
        root.desired = -1
        root.lastError = root.plain(String(actionErr.text || "").trim().split("\n").pop())
      }
      root.refresh()
    }
  }

  Process {
    id: locationsProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: locationsOut
      waitForEnd: true
      onStreamFinished: {
        try {
          root.allLocations = JSON.parse(locationsOut.text)
        } catch (e) {
          root.allLocations = []
        }
      }
    }
  }

  Process {
    id: clearProcess
    running: false
    command: []
    onExited: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function on(): string { root.runAction("on"); return "ok" }
    function off(): string { root.runAction("off"); return "ok" }
    function fastest(): string { root.runAction("fastest"); return "ok" }
    function nearest(): string { root.runAction("nearest"); return "ok" }
    function same(): string { root.runAction("same"); return "ok" }
    function usa(): string { root.runAction("usa"); return "ok" }
    function random(): string { root.runAction("random"); return "ok" }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Surfshark — " + root.statusPhrase
    iconComponent: Component {
      Item {
        SurfsharkIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          crossed: !root.shown
          wave: root.shown
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleVpn()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "t") root.toggleVpn()
        else if (k === "f") root.runAction("fastest")
        else if (k === "n") root.runAction("nearest")
        else if (k === "s") root.runAction("same")
        else if (k === "u") root.runAction("usa")
        else if (k === "x") root.runAction("random")
        else if (k === "r") root.refresh()
        else if (k === "/") searchField.forceActiveFocus()
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
            id: hero
            width: parent.width
            title: root.shown && root.location ? root.location : "Surfshark"
            // While something is missing the hero says what; otherwise it rotates.
            meta: (!root.daemonReady || !root.configured)
                  ? root.statusPhrase.toUpperCase()
                  : root.statePhrase.toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.shown ? 1.0 : 0.5
            iconComponent: Component {
              SurfsharkIcon {
                iconSize: Style.font.display
                color: root.foreground
                crossed: !root.shown
                wave: root.shown
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                checked: root.shown
                busy: root.busy
                enabled: root.configured && root.daemonReady
                foreground: hero.foreground
                onToggled: root.toggleVpn()
              }
            }
          }

          // Without the key there is nothing to switch on, so instead of failing
          // silently the panel spells out what is missing.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.configured || !root.daemonReady
            text: !root.daemonReady
                  ? "The Surfshark daemon is not running. Start the Surfshark app, or: systemctl --user start surfsharkd"
                  : "Connect once through the Surfshark app — this widget picks up the account's WireGuard key from there and runs on its own after that."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.lastError !== ""
            text: root.lastError
            color: root.foreground
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.configured && root.daemonReady

            PanelSectionHeader {
              width: parent.width
              text: "QUICK CONNECT"
            }

            ActionRow {
              width: parent.width
              label: "Fastest location"
              detail: "Surfshark's pick"
              onActivated: root.runAction("fastest")
            }

            ActionRow {
              width: parent.width
              label: "Nearest country"
              detail: "closest abroad"
              onActivated: root.runAction("nearest")
            }

            ActionRow {
              width: parent.width
              label: "Same country"
              detail: root.myCountry || "unknown"
              onActivated: root.runAction("same")
            }

            ActionRow {
              width: parent.width
              label: "United States"
              detail: root.usLabel
              onActivated: root.runAction("usa")
            }

            ActionRow {
              width: parent.width
              label: "Random country"
              detail: "surprise me"
              onActivated: root.runAction("random")
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.configured && root.daemonReady && root.recentList.length > 0

            Item {
              width: parent.width
              implicitHeight: recentHeader.implicitHeight

              PanelSectionHeader {
                id: recentHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "RECENT"
              }

              // Clears the list. Deliberately unconfirmed: only history is lost,
              // and every location is still one search away.
              Text {
                textFormat: Text.PlainText
                id: clearButton
                anchors.right: parent.right
                anchors.verticalCenter: recentHeader.verticalCenter
                text: "CLEAR"
                color: root.foreground
                opacity: clearMouse.containsMouse ? 1.0 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true

                Behavior on opacity { NumberAnimation { duration: 120 } }

                MouseArea {
                  id: clearMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.clearRecent()
                }
              }
            }

            Repeater {
              model: root.recentList
              ActionRow {
                required property var modelData
                width: parent.width
                label: root.plain(modelData.location || modelData.connectionName)
                detail: root.plain(modelData.country)
                current: root.shown && root.plain(modelData.location) === root.location
                onActivated: root.connectTo(String(modelData.connectionName || ""))
              }
            }
          }

          // Search across every location. Results appear only once something is
          // typed, so an idle panel does not grow by seven empty rows.
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.configured && root.daemonReady

            PanelSectionHeader {
              width: parent.width
              text: "ALL LOCATIONS"
            }

            TextField {
              id: searchField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Search locations"
              text: root.query
              onTextChanged: root.query = text
              // Enter takes the first hit — the common case is typing two or
              // three letters and confirming.
              onAccepted: if (root.results.length > 0)
                            root.connectTo(String(root.results[0].connectionName))
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  // First Escape clears the query, the second leaves the field —
                  // otherwise the only way out would be the mouse.
                  if (root.query !== "") root.query = ""
                  else keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.query.trim() !== "" && root.results.length === 0
              text: "No location matches “" + root.query.trim() + "”."
              color: root.dim
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.results
              ActionRow {
                required property var modelData
                width: parent.width
                label: root.plain(modelData.location)
                detail: root.plain(modelData.country)
                current: root.shown && root.plain(modelData.location) === root.location
                onActivated: root.connectTo(String(modelData.connectionName || ""))
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.hiddenMatches > 0
              text: "+" + root.hiddenMatches + " more — keep typing to narrow"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.publicIp !== ""
            // The country is whatever the *current* public IP resolves to, not
            // where you are sitting: with the tunnel up that is the exit
            // server's country, so you can see where traffic actually leaves.
            text: {
              var parts = ["IP " + root.publicIp]
              if (root.myCountry) parts.push(root.myCountry)
              parts.push(root.secured ? "via Surfshark" : "direct")
              return parts.join(" · ")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  // Glyph-free row: the current selection is marked with a drawn dot, so the
  // row depends on no Nerd Font codepoint and stays single-colour.
  component ActionRow: CursorSurface {
    id: actionRow
    property string label: ""
    property string detail: ""
    property bool current: false
    signal activated()

    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowInner.implicitHeight + Style.spacing.xl

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Item {
        width: Style.space(12)
        height: rowLabel.implicitHeight
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: Style.space(5)
          height: width
          radius: width / 2
          color: root.foreground
          opacity: actionRow.current ? 1.0 : 0.28
        }
      }

      Text {
        textFormat: Text.PlainText
        id: rowLabel
        text: actionRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: actionRow.current
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - Style.space(12) - Style.space(8)
                           - rowDetail.implicitWidth - Style.space(8))
      }

      Text {
        textFormat: Text.PlainText
        id: rowDetail
        text: actionRow.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: actionRow.activated()
    }
  }
}
