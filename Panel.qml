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

  // The app whose tile was just clicked. Without this a tile stayed unlit
  // until the TV confirmed what was on screen, a second or more later, and
  // the click read as ignored.
  property string launchingApp: ""

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
    Qt.callLater(function() { root.send("press:" + key) })
  }

  function releaseKey(key) {
    if (heldKey === "") return
    heldKey = ""
    send("release:" + key)
    flash.restart()
  }

  function launchApp(key) {
    lastKey = "app:" + key
    launchingApp = key
    launchTimeout.restart()
    flash.restart()
    // Queued so the highlight is applied in this pass and painted before the
    // command goes anywhere near the network.
    Qt.callLater(function() { root.send("app:" + key) })
  }

  function rescanApps() {
    scanning = true
    send("scan")
  }

  function togglePin(key) {
    send("pin:" + key)
  }

  // 1-9 launch the tiles in order. A positional key suits a list whose
  // contents change with a rescan: the number belongs to the slot, not to a
  // particular app, and no selection cursor is needed to reach the fourth one.
  function launchNth(n) {
    if (n >= 1 && n <= pinnedApps.length) launchApp(String(pinnedApps[n - 1].key))
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

  // Gives up on a launch that never showed up, so a tile cannot stay lit
  // because an app failed to come to the front.
  Timer {
    id: launchTimeout
    interval: 5000
    onTriggered: root.launchingApp = ""
  }

  onForegroundAppChanged: if (foregroundApp === launchingApp) launchingApp = ""

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
        else if (text >= "1" && text <= "9") root.launchNth(parseInt(text))
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
            number: 1
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
                number: index + 2
              }
            }
          }

          // Everything else the last scan found on the TV, folded away so the
          // apps actually used keep the top of the panel. Rescan sits here
          // rather than at the foot of the panel, next to the list it
          // refreshes.
          Item {
            width: parent.width
            height: Style.space(20)

            Button {
              anchors.centerIn: parent
              visible: root.otherApps.length > 0
              text: (root.moreOpen ? "󰅃  " : "󰅀  ") + root.otherApps.length + " more on the TV"
              fontSize: Style.font.caption
              foreground: Color.muted
              tooltipText: "Apps found on the TV. Right-click one to pin it."
              onClicked: root.moreOpen = !root.moreOpen
            }

            Button {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.scanning ? "scanning…" : ""
              iconText: root.scanning ? "" : "󰑐"
              iconSize: Style.font.body
              fontSize: Style.font.caption
              foreground: Color.muted
              verticalPadding: Style.space(2)
              tooltipText: "Rescan the TV for installed apps"
              onClicked: if (!root.scanning) root.rescanApps()
            }
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

        // Each hint sits under the row it describes rather than in one legend
        // at the foot of the panel, so it is read next to the buttons it is
        // about. The app tiles need no line of their own -- they carry their
        // numbers.
        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          text: "arrows · enter · backspace"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
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

        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          text: "− + · m to mute"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // A streaming app.
  //
  // The TV serves no artwork for its apps -- there is no icon endpoint on
  // this firmware -- so the marks are the brand glyphs already in the bar's
  // Nerd Font. They are approximations of trademarks, not official assets:
  // fine for a personal widget, and the shapes are used unaltered, but a
  // published plugin should ship each brand's own files under its terms.
  //
  // Content is drawn here rather than through Button's text/iconText because
  // the two halves need different colours: a wordmark is neutral (YouTube's
  // guidance is explicit that the word stays black or white while the play
  // mark keeps the red), and only an app with no mark at all lets its name
  // carry the brand colour.
  component AppTile: Button {
    id: appTile
    property var app: null
    property bool primary: false
    property bool muted: false
    property int number: 0

    readonly property string glyph: app ? String(app.glyph || "") : ""
    readonly property string appName: app ? String(app.name) : ""
    readonly property color brand: app ? String(app.color) : root.fg
    // A third-width tile cannot hold a mark and a name without spilling, and
    // the mark alone is the more recognisable half.
    readonly property bool showName: primary || glyph === ""

    text: ""
    iconText: ""
    foreground: root.fg
    accent: brand
    opacity: muted ? 0.65 : 1
    bordered: true
    // Lit while the launch is in flight as well as once the TV confirms, so
    // the tile responds on the click rather than on the round trip.
    active: !!app && (root.foregroundApp === String(app.key)
                      || root.launchingApp === String(app.key))
    tooltipText: {
      if (!app) return ""
      var label = root.foregroundApp === String(app.key)
        ? appName + " — on screen now" : "Open " + appName
      if (number > 0) label += "  (press " + number + ")"
      return label + (muted ? "  · right-click to pin" : "  · right-click to unpin")
    }
    onClicked: if (app) { pressPulse.restart(); root.launchApp(String(app.key)) }
    onRightClicked: if (app) root.togglePin(String(app.key))

    SequentialAnimation {
      id: pressPulse
      NumberAnimation { target: appTile; property: "scale"; to: 0.95; duration: 70 }
      NumberAnimation { target: appTile; property: "scale"; to: 1.0; duration: 110 }
    }

    // The 1-9 shortcut is only usable if the number is on the tile.
    Text {
      textFormat: Text.PlainText
      visible: appTile.number > 0
      text: String(appTile.number)
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.leftMargin: Style.space(4)
      anchors.topMargin: Style.space(1)
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.spacing.controlGap

      Text {
        textFormat: Text.PlainText
        visible: appTile.glyph !== ""
        text: appTile.glyph
        color: appTile.brand
        font.family: root.fontFamily
        font.pixelSize: appTile.primary ? Style.font.heading : Style.font.iconLarge
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        visible: appTile.showName
        text: appTile.appName
        color: appTile.glyph !== "" ? root.fg : appTile.brand
        font.family: root.fontFamily
        font.pixelSize: appTile.primary ? Style.font.subtitle : Style.font.caption
        font.bold: appTile.primary
        anchors.verticalCenter: parent.verticalCenter
      }
    }
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

    SequentialAnimation {
      id: keyPulse
      NumberAnimation { target: keyButton; property: "scale"; to: 0.93; duration: 60 }
      NumberAnimation { target: keyButton; property: "scale"; to: 1.0; duration: 100 }
    }

    // Sits above Button's own MouseArea so a press and its release both land
    // here; Button.clicked is deliberately unused, since a tap is already the
    // short end of the same hold.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: false
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onPressed: { keyPulse.restart(); root.holdKey(keyButton.key) }
      onReleased: root.releaseKey(keyButton.key)
      onCanceled: root.releaseKey(keyButton.key)
    }
  }
}
