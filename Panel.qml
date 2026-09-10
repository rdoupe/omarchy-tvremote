import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
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
  // Empty means "find it". A published plugin cannot ship anyone's address,
  // and a hardcoded one would silently defeat discovery on every install but
  // the author's -- which is exactly what this line used to do.
  readonly property string host: String(setting("host", ""))
  readonly property int pollInterval: Math.max(15, parseInt(setting("pollIntervalSec", 60)) || 60) * 1000
  readonly property bool hideWhenOff: String(setting("hideWhenOff", false)) === "true"
  readonly property bool resumeLastApp: String(setting("resumeLastApp", true)) !== "false"
  readonly property bool pauseOnMicrophone: String(setting("pauseOnMicrophone", true)) !== "false"

  // The microphone button changes the default source's mute state. Remember
  // the first state we see so loading the shell with a live microphone is not
  // mistaken for someone pressing the button.
  readonly property var microphoneSource: Pipewire.defaultAudioSource
  readonly property bool microphoneMuted: microphoneSource && microphoneSource.audio
    ? microphoneSource.audio.muted : true
  property var observedMicrophoneSource: null
  property bool observedMicrophoneMuted: true

  // Device facts, refreshed by `tvctl state`.
  property bool reachable: false
  property bool paired: false
  // Whether a MAC has been learned, which is what makes wake-on-LAN possible.
  property bool canWake: false
  property bool waking: false
  property string wakeStage: ""

  // Candidate TVs from a discovery sweep. Populated only when the choice is
  // genuinely open -- one TV on the network is picked automatically, so this
  // list appearing means there were several (or none).
  property var tvChoices: []
  readonly property bool picking: tvChoices.length > 0
  // The TV is answering but has not authorised us: the Allow prompt is on
  // screen right now and nothing else will work until it is answered.
  readonly property bool needsPairing: reachable && !paired
  // The hotkey the user bound to this widget, read back from Hyprland rather
  // than hardcoded: a plugin cannot ship a binding (the manifest schema has
  // no field for one), so the only honest source for the hint is whatever is
  // actually bound right now. Empty means nothing is, and the hint stays off
  // rather than advertising a key that would do nothing.
  property string hotkey: ""
  property bool hotkeyChecked: false

  // A tokenless connect is in flight: the Allow/Deny prompt is on the TV
  // screen this second, and nothing comes back until someone answers it
  // there. Tracked because the prompt lives exactly as long as the
  // connection that raised it -- see closeDaemonIfIdle().
  property bool pairing: false
  // Nothing below the header is usable in either state.
  readonly property bool blocked: picking || needsPairing || helperBroken
  property string wakeTarget: ""
  property bool poweringOff: false
  // Set when a wake ran its full course and the TV still did not come on --
  // nearly always one TV setting rather than a fault, so the panel offers
  // the fix instead of an error.
  property bool wakeFailed: false
  // The helper never produced a line and exited: the widget cannot work, and
  // saying so beats a permanently blank panel.
  property bool helperBroken: false
  property bool helperSpoke: false
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

  function syncMicrophoneState() {
    var source = microphoneSource
    if (!source || !source.audio) {
      observedMicrophoneSource = null
      observedMicrophoneMuted = true
      return
    }

    var currentMuted = !!source.audio.muted
    if (observedMicrophoneSource !== source) {
      observedMicrophoneSource = source
      observedMicrophoneMuted = currentMuted
      return
    }

    var microphoneActivated = observedMicrophoneMuted && !currentMuted
    observedMicrophoneMuted = currentMuted
    // Omarchy creates a widget instance for every monitor and a few layout
    // placeholders. Elect one live instance so a single mic press sends one
    // pause instead of one pause per instance.
    var widgets = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : []
    var ownsAutomation = widgets.length === 0 || widgets[0] === root
    if (microphoneActivated && ownsAutomation && pauseOnMicrophone
        && reachable && power === "on") {
      if (daemon.running) send("pause")
      else if (!pauseProc.running) pauseProc.running = true
    }
  }

  onMicrophoneSourceChanged: syncMicrophoneState()
  onMicrophoneMutedChanged: syncMicrophoneState()
  Component.onCompleted: syncMicrophoneState()

  PwObjectTracker { objects: root.microphoneSource ? [root.microphoneSource] : [] }

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
    // A tile clicked on a sleeping TV is a request to turn it on and open
    // that app, not an error.
    if (!reachable && canWake) {
      wakeTv(key)
      return
    }
    lastKey = "app:" + key
    launchingApp = key
    launchTimeout.restart()
    flash.restart()
    // Queued so the highlight is applied in this pass and painted before the
    // command goes anywhere near the network.
    Qt.callLater(function() { root.send("app:" + key) })
  }

  // A TV that is off answers nothing on any port, so powering it on cannot
  // go over the remote socket -- it takes a magic packet to the NIC, which
  // stays listening while the set sleeps.
  // `app` turns "the TV is off" into "open Netflix": wake it, then go
  // straight there, which is what clicking a tile on a sleeping TV means.
  function wakeTv(app) {
    wakeFailed = false
    waking = true
    wakeStage = ""
    wakeTarget = app || ""
    wakeTimeout.restart()
    send(app ? ("wake:" + app) : "wake")
  }

  // The whole sequence -- packet, boot, power key, reopening the last app --
  // runs to about a minute on this set, so the giving-up point is generous.
  readonly property string wakeLabel: {
    if (wakeStage === "resume") {
      var app = appName(wakeTarget)
      return app ? "opening " + app + "…" : "reopening your last app…"
    }
    if (wakeStage === "network") return "waking… TV is in standby"
    if (wakeStage === "power") return "waking… turning the screen on"
    return "waking… this takes about a minute"
  }

  function appName(key) {
    for (var i = 0; i < apps.length; i++)
      if (String(apps[i].key) === key) return String(apps[i].name)
    return ""
  }

  function pickTv(ip) {
    tvChoices = []
    send("pick:" + ip)
  }

  function rediscover() {
    scanning = true
    send("rediscover")
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
    helperSpoke = true
    helperBroken = false
    var msg
    try {
      msg = JSON.parse(line)
    } catch (e) {
      return
    }
    if (msg.type === "state") {
      reachable = !!msg.reachable
      // A live remote socket is itself proof of authorisation: the TV sends
      // ms.channel.connect only once it has allowed us, and 2015 sets allow
      // with no token to show for it. So a poll may raise this but never
      // lower it under a working connection.
      paired = !!msg.paired || linkUp
      if (msg.canWake !== undefined) canWake = !!msg.canWake
      if (!reachable || power !== "on") poweringOff = false
      // Not merely "reachable": the magic packet makes the TV answer while
      // it is still in standby with the screen off, so the wake is not done
      // until it actually reports itself on.
      if (power === "on") { waking = false; wakeStage = "" }
      tvName = String(msg.name || "TV")
      power = String(msg.power || "unknown")
      if (msg.volume !== undefined) volume = parseInt(msg.volume)
      muted = !!msg.muted
      if (msg.app !== undefined) foregroundApp = String(msg.app || "")
      if (reachable) errorText = ""
    } else if (msg.type === "volume") {
      volume = parseInt(msg.volume)
      muted = !!msg.muted
    } else if (msg.type === "tvs") {
      tvChoices = msg.tvs || []
      scanning = false
    } else if (msg.type === "picked") {
      tvChoices = []
      tvName = String(msg.name || "TV")
    } else if (msg.type === "wakefailed") {
      wakeFailed = true
      waking = false
      wakeStage = ""
    } else if (msg.type === "waking") {
      waking = true
      wakeStage = String(msg.stage || "")
      wakeTimeout.restart()
    } else if (msg.type === "apps") {
      apps = msg.apps || []
      if (msg.scanned) scanning = false
    } else if (msg.type === "scanning") {
      scanning = true
    } else if (msg.type === "app") {
      foregroundApp = String(msg.app || "")
    } else if (msg.type === "pairing") {
      pairing = true
      pairingTimeout.restart()
    } else if (msg.type === "connected") {
      linkUp = true
      errorText = ""
      pairing = false
      pairingTimeout.stop()
      // Pressing Allow on the TV used to change nothing here: `paired` moved
      // only on a state poll, and that poll is off while the popup is open
      // (see the timer below), so the "Look at your TV" screen outlived the
      // pairing it was asking for. The only way out was to close the panel
      // and wait a minute -- which is why this took three tries. The socket
      // being up is all the proof needed, so say so immediately and ask for
      // the authoritative state behind it.
      if (msg.paired_now || !paired) {
        paired = true
        send("state")
      }
    } else if (msg.type === "disconnected") {
      linkUp = false
    } else if (msg.type === "error") {
      errorText = String(msg.msg || "")
      pairing = false
      pairingTimeout.stop()
      scanning = false
    }
  }

  Process {
    id: daemon
    command: [root.helper, "serve"]
    environment: ({ "TV_HOST": root.host,
                    "TV_RESUME_APP": root.resumeLastApp ? "1" : "0" })
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.errorText = line } }
    onStarted: {
      var queue = root.pendingKeys
      root.pendingKeys = []
      for (var i = 0; i < queue.length; i++) daemon.write(queue[i] + "\n")
    }
    onExited: function(exitCode) {
      root.linkUp = false
      root.pendingKeys = []
      // Exited without ever saying anything: the interpreter or the helper
      // itself is missing, not a TV problem.
      if (!root.helperSpoke && exitCode !== 0) root.helperBroken = true
    }
  }

  // Hyprland's own bind table is the source of truth. Matched on the bind's
  // description, because Omarchy routes its bindings through a Lua dispatcher
  // whose arg is an opaque table index -- the command string is not in there
  // to match on.
  Process {
    id: hotkeyProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readHotkey(text)
    }
  }

  function readHotkey(payload) {
    root.hotkeyChecked = true
    var binds
    try {
      binds = JSON.parse(payload)
    } catch (e) {
      return
    }
    if (!Array.isArray(binds)) return
    for (var i = 0; i < binds.length; i++) {
      var b = binds[i]
      var desc = String(b.description || "").toLowerCase()
      var arg = String(b.arg || "")
      // Either the description names this remote, or the binding runs the
      // plugin directly (a plain exec rather than through Omarchy's Lua).
      if (desc.indexOf("tv remote") < 0 && arg.indexOf(root.moduleName) < 0) continue
      var label = root.describeBind(b)
      if (label !== "") { root.hotkey = label; return }
    }
  }

  // modmask is an X11 modifier bitfield. Ordered the way the binding is
  // written in hypr/bindings.lua, so the hint can be copied straight back.
  function describeBind(b) {
    var key = String(b.key || "")
    if (key === "") return ""
    var mask = parseInt(b.modmask) || 0
    var parts = []
    if (mask & 64) parts.push("SUPER")
    if (mask & 4) parts.push("CTRL")
    if (mask & 8) parts.push("ALT")
    if (mask & 1) parts.push("SHIFT")
    parts.push(key.length === 1 ? key.toUpperCase() : key)
    return parts.join(" + ")
  }

  // Cheap liveness for the bar tooltip while the panel is closed: an HTTP GET
  // at the TV, no remote-control socket and no pairing involved.
  Process {
    id: stateProc
    command: [root.helper, "state"]
    environment: ({ "TV_HOST": root.host })
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
  }

  // A one-shot helper keeps microphone-triggered pauses independent of the
  // panel daemon, which normally exists only while the remote is open.
  Process {
    id: pauseProc
    command: [root.helper, "pause"]
    environment: ({ "TV_HOST": root.host })
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
    id: powerOffTimeout
    interval: 20000
    onTriggered: root.poweringOff = false
  }

  Timer {
    id: wakeTimeout
    interval: 90000
    onTriggered: { root.waking = false; root.wakeStage = "" }
  }

  Timer {
    id: launchTimeout
    interval: 5000
    onTriggered: root.launchingApp = ""
  }

  // tvctl gives a tokenless connect a 25s handshake and a 45s read, so a
  // prompt resolves well inside this. The timer is only here so that a child
  // which somehow says nothing at all cannot pin itself open for good.
  Timer {
    id: pairingTimeout
    interval: 120000
    onTriggered: root.pairing = false
  }

  onForegroundAppChanged: if (foregroundApp === launchingApp) launchingApp = ""

  // The child outlives a closed popup in exactly two cases. A wake is a
  // minute-long sequence -- magic packet, boot, power key, reopening the app
  // -- that quitting would strand halfway. And a pairing prompt lives only as
  // long as the connection that raised it, so quitting while it is on screen
  // dismisses the prompt the user is walking across the room to answer.
  // Both resolve on their own, and both call back here when they do.
  function closeDaemonIfIdle() {
    if (opened || waking || pairing) return
    if (daemon.running) daemon.write("quit\n")
    linkUp = false
  }

  onWakingChanged: closeDaemonIfIdle()
  onPairingChanged: closeDaemonIfIdle()

  onOpenedChanged: {
    if (opened) {
      errorText = ""
      // A child kept alive through a pairing prompt or a wake is already
      // connected and will not announce itself again, so ask it where things
      // stand rather than showing a stale picture.
      if (!daemon.running) daemon.running = true
      else send("state")
      // Once per shell session: the binding does not change under us, and
      // the bind table is a few thousand lines to parse.
      if (!hotkeyChecked && !hotkeyProc.running) hotkeyProc.running = true
    } else {
      // Never leave a key down: the TV would keep repeating with the panel
      // gone. (tvctl releases on exit too, but the panel should not rely on
      // its own shutdown path to stop the volume climbing.)
      if (heldKey !== "") releaseKey(heldKey)
      // A wake is a minute-long sequence -- magic packet, boot, power key,
      // reopening the app -- and quitting the helper mid-way kills the
      // daemon thread running it, leaving the TV stranded in standby with
      // the packet already sent. Let it finish; onWakingChanged closes up.
      closeDaemonIfIdle()
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
        else if (text === "p") {
          // Same path as the power button click: off when reachable, else wake.
          if (root.reachable) {
            root.poweringOff = true
            powerOffTimeout.restart()
            root.press("power")
          } else if (root.canWake) {
            root.wakeTv("")
          }
        }
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
              text: root.waking ? root.wakeLabel
                : root.poweringOff ? "turning off " + root.tvName + "…"
                : !root.reachable ? (root.canWake
                    ? "off — press ⏻ or an app to turn it on"
                    : "off or unreachable")
                : root.needsPairing ? "waiting for you to allow it"
                : root.errorText !== "" ? root.errorText
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
            tooltipText: root.reachable ? "Power off  (p)"
              : root.canWake ? "Wake the TV (wake-on-LAN)  (p)"
              : "TV is off, and no MAC is known yet to wake it"
            enabled: root.reachable || root.canWake
            opacity: enabled ? 1 : 0.4
            active: root.lastKey === "power" || root.waking
            onClicked: {
              if (root.reachable) {
                root.poweringOff = true
                powerOffTimeout.restart()
                root.press("power")
              } else {
                root.wakeTv("")
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "p"
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.leftMargin: Style.space(4)
              anchors.topMargin: Style.space(1)
            }
          }
        }

        // ---------- the helper cannot run ----------
        // python3 is pulled in by uwsm, which Omarchy requires, so this
        // should never fire -- but a widget that silently does nothing is
        // the worst way to find out otherwise.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.helperBroken

          Text {
            textFormat: Text.PlainText
            text: "Can't start the helper"
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            // No install command here on purpose: python3 is guaranteed on
            // Omarchy (omarchy -> uwsm -> python), so a missing interpreter
            // is not the likely cause, and shipping a privileged command in
            // a plugin earns a manual review it does not need.
            text: "It needs python3 on PATH, and tvctl must be executable. "
                  + "Check the helper, then try again:"
            color: Color.muted
            width: parent.width
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: "chmod +x " + root.helper
            color: root.fg
            width: parent.width
            wrapMode: Text.WrapAnywhere
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "try again"
            fontSize: Style.font.caption
            foreground: root.fg
            bordered: true
            onClicked: { root.helperBroken = false; root.send("state") }
          }
        }

        // ---------- the TV would not wake ----------
        // Wake-on-LAN needs the TV's own network-standby setting, which ships
        // off on many sets. That is a setting, not a fault, so the panel says
        // which one rather than reporting failure.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.wakeFailed && !root.blocked

          Text {
            textFormat: Text.PlainText
            text: "Couldn't wake " + root.tvName
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: "Turn on network standby so the TV keeps listening while "
                  + "it sleeps:\nSettings → General → Network → Expert "
                  + "Settings → Power On with Mobile."
            color: Color.muted
            width: parent.width
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)

            Button {
              text: "try again"
              fontSize: Style.font.caption
              foreground: root.fg
              bordered: true
              onClicked: root.wakeTv("")
            }

            Button {
              text: "dismiss"
              fontSize: Style.font.caption
              foreground: Color.muted
              onClicked: root.wakeFailed = false
            }
          }
        }

        // ---------- waiting to be allowed on the TV ----------
        // The prompt is on the TV, not here, and there is nothing to click in
        // this panel that will help -- so the panel says where to look rather
        // than showing a remote that cannot work yet.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.needsPairing

          Text {
            textFormat: Text.PlainText
            text: "Look at your TV"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: "Press Allow on the prompt to let this remote control "
                  + root.tvName + "."
            color: Color.muted
            width: parent.width
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: "No prompt? It may have been denied before — clear this "
                  + "device under Settings → General → External Device "
                  + "Manager → Device Connect Manager."
            color: Color.muted
            width: parent.width
            wrapMode: Text.WordWrap
            opacity: 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            visible: !root.pairing
          }

          // While a prompt is genuinely up, the only useful thing this panel
          // can do is stay out of the way and keep the connection alive.
          Text {
            textFormat: Text.PlainText
            text: "Waiting for the TV… take your time, this stays open."
            color: Color.muted
            width: parent.width
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            visible: root.pairing
          }

          // Deliberately hidden while a prompt is live. Asking again opens a
          // second connection, and the TV dismisses the pending prompt when
          // it does -- so this button, pressed during the wait it appears in,
          // was cancelling the very thing the user was about to allow.
          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "ask again"
            fontSize: Style.font.caption
            foreground: root.fg
            bordered: true
            visible: !root.pairing
            onClicked: root.send("reconnect")
          }
        }

        // ---------- choose a TV (first launch, several found) ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.picking

          Text {
            textFormat: Text.PlainText
            text: "Several TVs on the network — which one?"
            color: Color.muted
            width: parent.width
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.tvChoices.length

            Button {
              width: parent.width
              height: Style.space(26)
              text: String(root.tvChoices[index].name)
              fontSize: Style.font.body
              foreground: root.fg
              bordered: true
              tooltipText: String(root.tvChoices[index].model) + "  ·  "
                           + String(root.tvChoices[index].ip)
              onClicked: root.pickTv(String(root.tvChoices[index].ip))
            }
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.scanning ? "searching…" : "search again"
            fontSize: Style.font.caption
            foreground: Color.muted
            onClicked: if (!root.scanning) root.rediscover()
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
          visible: root.apps.length > 0 && !root.blocked

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
          visible: !root.blocked
          anchors.horizontalCenter: parent.horizontalCenter
          columns: 3
          spacing: Style.space(4)

          Item { width: root.keySize; height: root.keySize }
          RemoteKey { key: "up"; glyph: "󰅃"; tip: "Up" }
          Item { width: root.keySize; height: root.keySize }

          RemoteKey { key: "left"; glyph: "󰅁"; tip: "Left" }
          RemoteKey { key: "enter"; glyph: ""; label: "OK"; tip: "OK  (Enter)" }
          RemoteKey { key: "right"; glyph: "󰅂"; tip: "Right" }

          Item { width: root.keySize; height: root.keySize }
          RemoteKey { key: "down"; glyph: "󰅀"; tip: "Down" }
          RemoteKey { key: "back"; glyph: "󰌑"; tip: "Back  (Backspace)"; shortcutHint: "⌫" }
        }

        // Shortcut hints live on the buttons themselves (same corner style as
        // the app-tile numbers), so the under-row legend lines are gone.

        // ---------- volume ----------
        Row {
          visible: !root.blocked
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(4)

          RemoteKey { key: "voldown"; glyph: "󰍴"; tip: "Volume down  (−)"; shortcutHint: "-" }

          Item {
            width: root.keySize
            height: root.keySize

            // Mute shortcut hint — same corner caption style as AppTile numbers.
            Text {
              textFormat: Text.PlainText
              text: "m"
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.leftMargin: Style.space(4)
              anchors.topMargin: Style.space(1)
              z: 1
            }

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

          // Display "=" (unshifted key); onTextKey still accepts "+" too.
          RemoteKey { key: "volup"; glyph: "󰐕"; tip: "Volume up  (=)"; shortcutHint: "=" }
        }

        // ---------- how to get back here ----------
        // The whole point of the widget is that the popup takes the keyboard,
        // so the one shortcut that is not printed on a button is the one that
        // opens it. Shown only when something really is bound (read back from
        // Hyprland), in the same muted caption style as the button hints.
        Text {
          textFormat: Text.PlainText
          visible: root.hotkey !== "" && !root.blocked
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.hotkey + "  ·  opens this"
          color: Color.muted
          opacity: 0.75
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
    // the tile responds on the click rather than on the round trip. A launch
    // in flight wins outright rather than adding to the foreground tile:
    // otherwise the app being left and the app being opened are both lit for
    // the second or two the TV takes to switch.
    active: !!app && (root.launchingApp !== ""
                      ? root.launchingApp === String(app.key)
                      : root.foregroundApp === String(app.key))
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
    // Optional corner caption, same style as AppTile's number hint.
    property string shortcutHint: ""

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

    Text {
      textFormat: Text.PlainText
      visible: keyButton.shortcutHint !== ""
      text: keyButton.shortcutHint
      color: Color.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.leftMargin: Style.space(4)
      anchors.topMargin: Style.space(1)
      z: 1
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
