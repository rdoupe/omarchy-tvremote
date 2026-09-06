import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A Samsung TV's remote in the bar. Keys go over the Tizen remote-control
// WebSocket (see tvctl); the panel never touches the network itself.
//
// Two things shape the design:
//
//   The channel is write-only. The TV acknowledges that it took a key and
//   reports nothing else -- not the volume, not what is on screen. So the
//   volume number here is read separately over UPnP after a volume key, and
//   everything else the panel shows comes from the /api/v2/ device endpoint.
//
//   A handshake per keypress is too slow to steer a menu with. tvctl therefore
//   runs as a `serve` child holding one socket open, and a press is a single
//   line on its stdin. The child lives only while the panel is open; the bar
//   tooltip is fed by a much cheaper one-shot poll.
//
// While the panel has focus the physical arrow keys, Enter, and Backspace
// drive the TV directly, which is the point of the whole widget -- the D-pad
// is there for the mouse.
Panel {
  id: root
  moduleName: "io.github.rdoupe.tvremote"
  ipcTarget: "io.github.rdoupe.tvremote"

  readonly property string helper: String(Qt.resolvedUrl("tvctl")).replace(/^file:\/\//, "")
  readonly property string host: String(setting("host", "192.168.100.59"))
  readonly property int pollInterval: Math.max(15, parseInt(setting("pollIntervalSec", 60)) || 60) * 1000
  readonly property bool hideWhenOff: String(setting("hideWhenOff", false)) === "true"

  // Device facts, refreshed by `tvctl state`.
  property bool reachable: false
  property bool paired: false
  property string tvName: "TV"
  property string power: "unknown"
  property int volume: -1
  property bool muted: false

  // Link state of the serve child's socket, and the last key it confirmed --
  // the only feedback the TV gives, so the panel flashes the button that
  // actually landed rather than the one that was clicked.
  property bool linkUp: false
  property string lastKey: ""
  property string errorText: ""

  // Streaming apps come from tvctl's config file, not from here, and the TV
  // cannot be asked what it has installed -- `scan` probes known ids one at a
  // time. So the list is whatever the last scan (or a hand edit) settled on.
  property var apps: []
  property string foregroundApp: ""
  property bool scanning: false
  property bool moreOpen: false

  // The key currently held down. Press/Release is what the physical remote
  // sends, so the TV runs its own repeat acceleration for as long as a button
  // is down -- a tap is just a very short hold.
  property string heldKey: ""

  // Tiles vs discoveries: a scan finds everything on the TV, but only pinned
  // apps get a tile. Right-click moves an app between the two.
  readonly property var pinnedApps: apps.filter(function(a) { return a.show !== false })
  readonly property var otherApps: apps.filter(function(a) { return a.show === false })

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real keySize: Style.space(44)

  readonly property string volumeIcon: muted ? "󰝟"
    : volume <= 0 ? "󰖁"
    : volume < 30 ? "󰖀"
    : "󰕾"

  // ---------------------------------------------------------------- backend

  // Keys pressed before the child is up (the panel starts it on open, and a
  // fast click can beat it) wait here rather than being dropped.
  property var pendingKeys: []

  function send(command) {
    if (daemon.running) {
      daemon.write(command + "\n")
    } else {
      var queue = pendingKeys.slice()
      queue.push(command)
      pendingKeys = queue
      daemon.running = true
    }
  }

  function press(key) {
    lastKey = key
    flash.restart()
    send(key)
  }

  function holdKey(key) {
    if (heldKey !== "") releaseKey(heldKey)
    heldKey = key
    lastKey = key
    flash.stop()
    send("press:" + key)
  }

  function releaseKey(key) {
    if (heldKey === "") return
    heldKey = ""
    send("release:" + key)
    flash.restart()
  }

  function launchApp(key) {
    lastKey = "app:" + key
    flash.restart()
    send("app:" + key)
  }

  function rescanApps() {
    scanning = true
    send("scan")
  }

  function togglePin(key) {
    send("pin:" + key)
  }

  function handleLine(line) {
    var msg
    try {
      msg = JSON.parse(line)
    } catch (e) {
      return
    }
    if (msg.type === "state") {
      reachable = !!msg.reachable
      paired = !!msg.paired
      tvName = String(msg.name || "TV")
      power = String(msg.power || "unknown")
      if (msg.volume !== undefined) volume = parseInt(msg.volume)
      muted = !!msg.muted
      if (msg.app !== undefined) foregroundApp = String(msg.app || "")
      if (reachable) errorText = ""
    } else if (msg.type === "volume") {
      volume = parseInt(msg.volume)
      muted = !!msg.muted
    } else if (msg.type === "apps") {
      apps = msg.apps || []
      if (msg.scanned) scanning = false
    } else if (msg.type === "scanning") {
      scanning = true
    } else if (msg.type === "app") {
      foregroundApp = String(msg.app || "")
    } else if (msg.type === "connected") {
      linkUp = true
      errorText = ""
    } else if (msg.type === "disconnected") {
      linkUp = false
    } else if (msg.type === "error") {
      errorText = String(msg.msg || "")
      scanning = false
    }
  }

  Process {
    id: daemon
    command: [root.helper, "serve"]
    environment: ({ "TV_HOST": root.host })
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.errorText = line } }
    onStarted: {
      var queue = root.pendingKeys
      root.pendingKeys = []
      for (var i = 0; i < queue.length; i++) daemon.write(queue[i] + "\n")
    }
    onExited: {
      root.linkUp = false
      root.pendingKeys = []
    }
  }

  // Cheap liveness for the bar tooltip while the panel is closed: an HTTP GET
  // at the TV, no remote-control socket and no pairing involved.
  Process {
    id: stateProc
    command: [root.helper, "state"]
    environment: ({ "TV_HOST": root.host })
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
  }

  Timer {
    interval: root.pollInterval
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!stateProc.running && !daemon.running) stateProc.running = true
  }

  // Clears the pressed-key highlight; purely cosmetic.
  Timer {
    id: flash
    interval: 220
    onTriggered: root.lastKey = ""
  }

  onOpenedChanged: {
    if (opened) {
      errorText = ""
      if (!daemon.running) daemon.running = true
    } else {
      // Never leave a key down: the TV would keep repeating with the panel
      // gone. (tvctl releases on exit too, but the panel should not rely on
      // its own shutdown path to stop the volume climbing.)
      if (heldKey !== "") releaseKey(heldKey)
      if (daemon.running) daemon.write("quit\n")
      linkUp = false
    }
  }

  function tooltip() {
    if (!reachable) return tvName + " — off or unreachable"
    var parts = [tvName]
    if (volume >= 0) parts.push(muted ? "muted" : "vol " + volume)
    if (!paired) parts.push("not paired")
    return parts.join("  ·  ")
  }

  // ------------------------------------------------------------ bar widget

  readonly property bool shown: reachable || !hideWhenOff
  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A set with an antenna (md-television_classic, U+F07F4). A flat-screen
    // glyph is a coin-flip against the monitor widget's icon two slots over;
    // the antenna is what makes this read as a TV and not a display.
    text: "󰟴"
    active: root.opened
    opacity: root.reachable ? 1 : 0.45
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.press("mute")
      else root.toggle()
    }
    // Volume without opening anything: the most common thing wanted from a
    // TV remote is one notch up or down.
    onWheelMoved: function(delta) { root.press(delta > 0 ? "volup" : "voldown") }
  }

  // ----------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(250))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // No cursor model: the panel is a remote, so a movement key IS the
      // command. hjkl comes along with the arrows for free.
      onMoveRequested: function(dx, dy) {
        if (dy < 0) root.press("up")
        else if (dy > 0) root.press("down")
        else if (dx < 0) root.press("left")
        else root.press("right")
      }
      onActivateRequested: root.press("enter")
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Backspace is the natural "back", and PanelKeyCatcher claims no key
      // that produces text, so it arrives here as \b rather than through a
      // Keys handler of our own -- KeyboardPanel is not an Item, so there is
      // nowhere above the catcher to attach one.
      onTextKey: function(text) {
        if (text === "\b" || text === "\u007f" || text === "b") root.press("back")
        else if (text === "+" || text === "=") root.press("volup")
        else if (text === "-" || text === "_") root.press("voldown")
        else if (text === "m") root.press("mute")
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroText.implicitHeight, powerButton.implicitHeight)

          Column {
            id: heroText
            anchors.left: parent.left
            anchors.right: powerButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.tvName
              color: root.fg
              elide: Text.ElideRight
              width: parent.width
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            Text {
              textFormat: Text.PlainText
              text: !root.reachable ? "off or unreachable"
                : root.errorText !== "" ? root.errorText
                : !root.paired ? "waiting for Allow on the TV"
                : root.linkUp ? "connected" : "connecting…"
              color: root.errorText !== "" || !root.reachable ? Color.urgent : Color.muted
              elide: Text.ElideRight
              width: parent.width
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            id: powerButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐥"
            iconSize: Style.font.icon
            foreground: root.fg
            tooltipText: "Power"
            active: root.lastKey === "power"
            onClicked: root.press("power")
          }
        }

        // ---------- apps ----------
        // Directly under the header, because launching an app is the most
        // common reason to open this at all -- and the first configured app
        // gets the full-width tile, so the one you use most is the easiest
        // thing in the panel to hit.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.apps.length > 0

          AppTile {
            app: root.pinnedApps.length > 0 ? root.pinnedApps[0] : null
            width: parent.width
            height: Style.space(32)
            primary: true
          }

          Flow {
            id: appFlow
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: Math.max(0, root.pinnedApps.length - 1)
              AppTile {
                app: root.pinnedApps[index + 1]
                width: (appFlow.width - appFlow.spacing * 2) / 3
                height: Style.space(24)
              }
            }
          }

          // Everything else the last scan found on the TV, folded away so the
          // apps actually used keep the top of the panel.
          Button {
            visible: root.otherApps.length > 0
            width: parent.width
            height: Style.space(20)
            text: (root.moreOpen ? "󰅃  " : "󰅀  ") + root.otherApps.length + " more on the TV"
            fontSize: Style.font.caption
            foreground: Color.muted
            tooltipText: "Apps found on the TV. Right-click one to pin it."
            onClicked: root.moreOpen = !root.moreOpen
          }

          Flow {
            id: moreFlow
            width: parent.width
            spacing: Style.space(4)
            visible: root.moreOpen && root.otherApps.length > 0

            Repeater {
              model: root.otherApps.length
              AppTile {
                app: root.otherApps[index]
                width: (moreFlow.width - moreFlow.spacing * 2) / 3
                height: Style.space(22)
                muted: true
              }
            }
          }
        }

        // ---------- D-pad ----------
        Grid {
          anchors.horizontalCenter: parent.horizontalCenter
          columns: 3
          spacing: Style.space(4)

          Item { width: root.keySize; height: root.keySize }
          RemoteKey { key: "up"; glyph: "󰅃" }
          Item { width: root.keySize; height: root.keySize }

          RemoteKey { key: "left"; glyph: "󰅁" }
          RemoteKey { key: "enter"; glyph: ""; label: "OK" }
          RemoteKey { key: "right"; glyph: "󰅂" }

          Item { width: root.keySize; height: root.keySize }
          RemoteKey { key: "down"; glyph: "󰅀" }
          RemoteKey { key: "back"; glyph: "󰌑"; tip: "Back  (Backspace)" }
        }

        // ---------- volume ----------
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(4)

          RemoteKey { key: "voldown"; glyph: "󰍴"; tip: "Volume down  (−)" }

          Item {
            width: root.keySize
            height: root.keySize

            Column {
              anchors.centerIn: parent
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.volumeIcon
                color: root.muted ? Color.urgent : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.volume >= 0 ? String(root.volume) : "—"
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.press("mute")
            }
          }

          RemoteKey { key: "volup"; glyph: "󰐕"; tip: "Volume up  (+)" }
        }

        Item {
          width: parent.width
          implicitHeight: hint.implicitHeight

          Text {
            id: hint
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: rescanButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            // Kept short so it never crowds the rescan button; the rest of
            // the shortcuts live in the buttons' own tooltips.
            text: "arrows · enter · back"
            color: Color.muted
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The TV answers no "what is installed?" question, so the app list
          // is only ever as fresh as the last probe of known ids.
          Button {
            id: rescanButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.scanning ? "scanning…" : "rescan"
            fontSize: Style.font.caption
            foreground: Color.muted
            verticalPadding: Style.space(2)
            tooltipText: "Check the TV for installed apps"
            onClicked: if (!root.scanning) root.rescanApps()
          }
        }
      }
    }
  }

  // A streaming app. The TV serves no artwork for its apps -- there is no
  // icon endpoint on this firmware -- so the tile is the app's name in its
  // brand colour rather than a logo.
  component AppTile: Button {
    // Deliberately not `required`: a delegate that declares a required
    // property stops Repeater injecting `index`, which is how each tile
    // finds its app.
    property var app: null
    property bool primary: false
    property bool muted: false

    readonly property string glyph: app ? String(app.glyph || "") : ""

    // A third-width tile cannot hold a logo and a name without spilling, and
    // the logo alone is the more recognisable half -- so the name only shows
    // on the primary tile, or when the app has no mark at all.
    text: app && (primary || glyph === "") ? String(app.name) : ""
    iconText: glyph
    iconSize: primary ? Style.font.heading : Style.font.iconLarge
    fontSize: primary ? Style.font.subtitle : Style.font.caption
    foreground: app ? String(app.color) : root.fg
    accent: foreground
    opacity: muted ? 0.65 : 1
    bordered: true
    active: !!app && root.foregroundApp === String(app.key)
    tooltipText: app ? (active ? String(app.name) + " — on screen now"
                              : "Open " + String(app.name)
                                + (muted ? "  (right-click to pin)"
                                         : "  (right-click to unpin)")) : ""
    onClicked: if (app) root.launchApp(String(app.key))
    onRightClicked: if (app) root.togglePin(String(app.key))
  }

  // One key on the remote. Highlights on the TV's ack, not on the click.
  component RemoteKey: Button {
    id: keyButton
    required property string key
    property string glyph: ""
    property string label: ""
    property string tip: ""

    width: root.keySize
    height: root.keySize
    iconText: glyph
    text: label
    iconSize: Style.font.iconLarge
    fontSize: Style.font.body
    foreground: root.fg
    bordered: true
    active: root.lastKey === key || root.heldKey === key
    tooltipText: tip

    // Sits above Button's own MouseArea so a press and its release both land
    // here; Button.clicked is deliberately unused, since a tap is already the
    // short end of the same hold.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: false
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onPressed: root.holdKey(keyButton.key)
      onReleased: root.releaseKey(keyButton.key)
      onCanceled: root.releaseKey(keyButton.key)
    }
  }
}
